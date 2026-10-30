import AppKit
import BrowserCore
import BrowserShell
import ChromiumEngine
import ObjectiveC.runtime

/// Explicit synthetic lifecycle qualification. No production startup or global input changes.
@MainActor
enum OrbitDailyQA9Probe {
    static let bundleID = "lab.orbit.orbit.daily-qa9"

    static func configure(_ application: OrbitApplication) {
        guard activeSiteSessionConfiguration()?.syntheticGuard != nil,
              CommandLine.arguments.contains("--daily-qa9-offscreen") else { return }
        // AppKit otherwise constrains titled windows back onto the owner's desktop.
        if let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:))),
           let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.dailyQA9Frame(_:to:))) {
            method_exchangeImplementations(original, replacement)
        }
        if let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:))),
           let replacement = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.dailyQA9Order(_:relativeTo:))) {
            method_exchangeImplementations(original, replacement)
        }
        if Bundle.main.bundleIdentifier == bundleID {
            application.confirmQuit = { .quit }
            application.windowPresenter = { controller, _ in
                controller.window?.setFrame(NSRect(x: -4000, y: 100, width: 1280, height: 900), display: false)
                controller.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    static func owns(_ owner: OrbitWindowController) -> Bool {
        guard activeSiteSessionConfiguration()?.syntheticGuard != nil,
              activeSiteSessionConfiguration()?.usesMockKeychain == true,
              let window = owner.window, window.frame.maxX < 0,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }

    static func run(_ application: OrbitApplication, owner: OrbitWindowController,
                    command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID, owns(owner), let environment = application.environment,
              let base = command["base"].flatMap(URL.init(string:)), base.scheme == "http", base.host == "127.0.0.1",
              let window = owner.window, let registry = owner.palette.registry else { return ["refused": true] }
        var checks: [String: Any] = [:]
        func drain(_ controller: OrbitWindowController) async {
            await application.windows.waitForPendingCommands()
            await controller.session.waitForPendingCommands()
            try? await Task.sleep(for: .milliseconds(50))
            await application.windows.waitForPendingCommands()
            await controller.session.waitForPendingCommands()
        }
        func load(_ surface: ChromiumSurface?) async -> Bool {
            guard let surface else { return false }
            let end = ContinuousClock.now + .seconds(4)
            repeat { try? await Task.sleep(for: .milliseconds(20)) }
            while (!surface.isReady || surface.navigationState.isLoading) && ContinuousClock.now < end
            return surface.isReady && !surface.navigationState.isLoading
        }
        owner.palette.dismiss()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if command["step"] == "tabs" {
            var tabs: [TabID] = []
            for i in 0..<5 {
                owner.openTab(url: base.appendingPathComponent("rapid-\(i)"))
                await drain(owner)
                if let id = owner.session.organization?.selectedTab?.id { tabs.append(id) }
            }
            guard tabs.count == 5 else { return ["seedFailed": true] }
            let navigation = owner.session.organization!.tabNavigationItems
            let selectedIndex = navigation.firstIndex { $0.isSelected } ?? 0
            let expectedKeyboardTab = navigation[(selectedIndex + 40) % navigation.count].id
            var keys = true
            for _ in 0..<40 {
                guard owns(owner), let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
                    charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 0) else { return ["ownershipLost": true] }
                keys = application.commands.keyboard.handle(event) && keys
            }
            await drain(owner)
            checks["rapidKeysConsumed"] = keys
            checks["rapidKeysFinalSelection"] = owner.session.organization?.selectedTab?.id == expectedKeyboardTab
            var clicks = true
            for i in 0..<40 {
                guard owns(owner), let row = owner.sidebar.page.list.row(for: .tab(tabs[i % 5])) else { return ["missingRow": true] }
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard owns(owner), let event = NSEvent.mouseEvent(with: type,
                        location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return ["ownershipLost": true] }
                    NSApp.postEvent(event, atStart: false)
                }
                try? await Task.sleep(for: .milliseconds(15))
                if i % 5 == 4 { await drain(owner); clicks = clicks && owner.session.organization?.selectedTab?.id == tabs[4] }
            }
            checks["rapidMouseSelection"] = clicks
            owner.openTab(url: base.appendingPathComponent("links"))
            await drain(owner)
            let surface = owner.session.selectedSurface
            checks["linkPageLoaded"] = await load(surface)
            let before = owner.session.snapshot?.tabs.count ?? 0
            if let surface, owns(owner) {
                _ = await OrbitPerformanceProbe.evaluate(surface, "document.querySelector('a').click();({clicked:true})")
            }
            let end = ContinuousClock.now + .seconds(3)
            while owner.session.snapshot?.tabs.count == before, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
            await drain(owner)
            checks["pageLinkNewTab"] = owner.session.snapshot?.tabs.count == before + 1
            let peekURL = base.appendingPathComponent("peek")
            if let peek = owner.openPeek(peekURL) {
                checks["peekLoaded"] = await load(peek)
                _ = await owner.promotePeekToTab()?.value
                await drain(owner)
                checks["peekPromotedLive"] = owner.session.selectedSurface === peek && !owner.isPeekPresented
            }
            application.quickWindowPresenter = { _ in }
            application.openQuickWindow(url: base.appendingPathComponent("little"), source: owner)
            await application.waitForQuickWindowCommands()
            if let little = environment.quickWindows.values.first {
                checks["littleLoaded"] = await load(little.surface)
                let live = little.surface
                application.promoteQuickWindow(little)
                await application.waitForQuickWindowCommands()
                await drain(owner)
                checks["littlePromotedLive"] = little.isClosed && environment.liveControllers.contains { $0.session.selectedSurface === live }
            }
            checks["fifoDrained"] = !owner.session.hasPendingCommands
        } else if command["step"] == "spaces" {
            do {
                owner.openTab(url: base.appendingPathComponent("space-source"))
                await drain(owner)
                _ = await load(owner.session.selectedSurface)
                try? await Task.sleep(for: .milliseconds(200))
                let first = owner.session.snapshot!.activeSpaceID
                let second = try await environment.store.createSpace(name: "Synthetic second", profileID: owner.session.activeProfileID!)
                owner.session.refreshCatalog()
                await drain(owner)
                let neighbor = NSWindow(contentRect: NSRect(x: -4000, y: 100, width: 300, height: 200),
                    styleMask: [.titled], backing: .buffered, defer: false)
                neighbor.isReleasedWhenClosed = false
                defer { neighbor.close() }
                var samples: [[String: Any]] = []
                for mode in ["visible", "occluded", "hidden", "deactivated"] {
                    guard owns(owner) else { return ["ownershipLost": true] }
                    if mode == "hidden" || mode == "deactivated" {
                        if mode == "hidden" { NSApp.hide(nil) } else { neighbor.makeKeyAndOrderFront(nil) }
                        let hiddenTarget = owner.session.snapshot!.activeSpaceID == first ? second : first
                        owner.activateSpace(hiddenTarget)
                        await drain(owner)
                        checks[mode + "Selection"] = owner.session.snapshot?.activeSpaceID == hiddenTarget
                        if mode == "hidden" { NSApp.unhide(nil) }
                    }
                    if mode == "occluded" { NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window) }
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    let target = owner.session.snapshot!.activeSpaceID == first ? second : first
                    owner.sidebar.spaceSwipe.validate(catalog: owner.session.catalog, active: owner.session.snapshot?.activeSpaceID)
                    try? await Task.sleep(for: .milliseconds(200))
                    guard owns(owner) else { return ["ownershipLost": true] }
                    let keyBefore = window.isKeyWindow
                    let start = ProcessInfo.processInfo.systemUptime
                    let began = owner.sidebar.spaceSwipe.switchToSpace(target)
                    var offsets: [[Double]] = []
                    while owner.sidebar.spaceSwipe.isActive, ProcessInfo.processInfo.systemUptime - start < 2.5 {
                        offsets.append([ProcessInfo.processInfo.systemUptime - start, Double(owner.sidebar.spaceSwipe.offset)])
                        try? await Task.sleep(for: .milliseconds(8))
                    }
                    await drain(owner)
                    let publicationEnd = ContinuousClock.now + .seconds(1)
                    while owner.session.snapshot?.activeSpaceID != target, owner.session.hasPendingCommands,
                          ContinuousClock.now < publicationEnd { try? await Task.sleep(for: .milliseconds(10)) }
                    samples.append(["mode": mode, "keyBefore": keyBefore, "keyAfter": window.isKeyWindow, "began": began, "seconds": ProcessInfo.processInfo.systemUptime - start,
                                    "selected": owner.session.snapshot?.activeSpaceID == target, "offsets": offsets])
                }
                checks["settlements"] = samples
                checks["allSpaceSelections"] = samples.allSatisfy { $0["began"] as? Bool == true && $0["selected"] as? Bool == true }
                checks["fifoDrained"] = !owner.session.hasPendingCommands
            } catch { checks["failed"] = true }
        } else if command["step"] == "close" {
            do {
                let space = owner.session.snapshot!.activeSpaceID
                let victimID = UUID()
                application.inheritedContexts[victimID] = owner.session.captureContextInCommandOrder()
                _ = application.windows.newWindow(id: victimID)
                await application.windows.waitForPendingCommands()
                guard let victim = application.windows.windows[victimID] else { return ["createFailed": true] }
                application.windowPresenter(victim, true)
                victim.palette.registry = registry
                victim.openTab(url: base.appendingPathComponent("close-source"))
                await drain(victim)
                _ = await load(victim.session.selectedSurface)
                let surfaces = victim.session.ownedSurfaces
                guard owns(victim), let tab = victim.session.organization?.selectedTab?.id else { return ["ownershipLost": true] }
                let payload = SidebarDragPayload(sourceWindow: victim.id, spaceID: space, profileID: victim.session.activeProfileID!,
                    nodes: [.tab(tab)], rowCount: 1, grabOffsetX: 0)
                application.tearOff(payload, from: victim, at: NSPoint(x: -4200, y: 200))
                try? await Task.sleep(for: .milliseconds(100))
                guard owns(victim) else { return ["ownershipLost": true] }
                victim.window?.performClose(nil)
                try? await Task.sleep(for: .milliseconds(850))
                checks["tearOffSourceRetired"] = victim.session.isClosed && surfaces.allSatisfy(\.isDisposed)
                checks["tearOffNoEmptyWindow"] = environment.liveControllers.allSatisfy { $0 === owner || !$0.session.ownedSurfaces.isEmpty }
                let swipe = owner
                application.windowPresenter(swipe, true)
                NSApp.activate(ignoringOtherApps: true)
                swipe.palette.registry = registry
                swipe.palette.dismiss()
                let target = try await environment.store.createSpace(name: "Synthetic close target", profileID: owner.session.activeProfileID!)
                swipe.session.refreshCatalog()
                await drain(swipe)
                swipe.sidebar.spaceSwipe.automaticallyAdvances = false
                swipe.sidebar.spaceSwipe.validate(catalog: swipe.session.catalog, active: swipe.session.snapshot?.activeSpaceID)
                try? await Task.sleep(for: .milliseconds(250))
                guard owns(swipe) else { return ["ownershipLost": true] }
                checks["closeSwipeStarted"] = swipe.sidebar.spaceSwipe.switchToSpace(target)
                checks["closeMenuAccepted"] = registry.dispatch(.closeWindow, origin: .menu, target: registry.captureTarget(windowID: swipe.id))
                checks["closeSwipeRetired"] = swipe.session.isClosed && !swipe.sidebar.spaceSwipe.isActive
                await drain(swipe)
                try await environment.saveNow()
                let document = await environment.store.sessionDocument()
                try document.validate()
                checks["closedWindowsNotPersisted"] = !document.windows.contains { $0.id.rawValue == victim.id || $0.id.rawValue == swipe.id }
            } catch { checks["failed"] = true }
        } else if command["step"] == "commands" {
            owner.openTab(url: base.appendingPathComponent("editing"))
            await drain(owner)
            if let surface = owner.session.selectedSurface, await load(surface) {
                guard owns(owner) else { return ["ownershipLost": true] }
                _ = await OrbitPerformanceProbe.evaluate(surface, "document.querySelector('textarea').focus();document.querySelector('textarea').select();({ready:true})")
                _ = surface.focusDocument()
                checks["webUppercaseAccepted"] = registry.dispatch(.makeUpperCase, origin: .menu)
                await drain(owner)
                try? await Task.sleep(for: .milliseconds(500))
                checks["webValue"] = await OrbitPerformanceProbe.evaluate(surface, "({value:document.querySelector('textarea').value})")?["value"] as? String ?? ""
                checks["webUppercaseEffect"] = await OrbitPerformanceProbe.evaluate(surface, "({changed:document.querySelector('textarea').value==='HELLO WORLD'})")?["changed"] as? Bool == true
                guard owns(owner) else { return ["ownershipLost": true] }
                checks["webSmartQuotesAccepted"] = registry.dispatch(.smartQuotes, origin: .menu)
                checks["networkInspectorAccepted"] = registry.dispatch(.networkInspector, origin: .menu)
                await drain(owner)
                try? await Task.sleep(for: .milliseconds(400))
                checks["networkInspectorOpened"] = surface.hasDevTools
            }
            let info = BrowserDataCommands.buildInformation()
            let fields = (try? JSONSerialization.jsonObject(with: Data(info.utf8))) as? [String: String]
            checks["supportReportMetadataOnly"] = Set(fields?.keys.map { $0 } ?? []) == ["application", "version", "build", "system"]
        } else if command["step"] == "performance" {
            let occurrences = owner.session.snapshot?.tabs.map(\.occurrenceID) ?? []
            for occurrence in occurrences {
                owner.session.selectOccurrence(occurrence)
                await drain(owner)
                _ = await load(owner.session.selectedSurface)
            }
            let end = ContinuousClock.now + .seconds(10)
            while owner.session.ownedSurfaces.filter({ $0.isBrowserCreated && $0.isReady && !$0.navigationState.isLoading }).count < 20,
                  ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
            checks["tabs"] = owner.session.snapshot?.tabs.count ?? 0
            checks["loaded"] = owner.session.ownedSurfaces.filter { $0.isBrowserCreated && $0.isReady && !$0.navigationState.isLoading }.count
        } else if command["step"] == "restore" {
            let document = await environment.store.sessionDocument()
            checks["restoredTabs"] = document.tabs.count
            checks["selectedDocumentLoaded"] = await load(owner.session.selectedSurface)
            checks["fifoDrained"] = !owner.session.hasPendingCommands
        }
        return checks
    }
}

extension NSWindow {
    @objc fileprivate func dailyQA9Frame(_ frame: NSRect, to screen: NSScreen?) -> NSRect { frame }
    @objc fileprivate func dailyQA9Order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out, frame.maxX >= 0 { setFrameOrigin(NSPoint(x: -4000, y: 100)) }
        dailyQA9Order(place, relativeTo: otherWin)
    }
}
