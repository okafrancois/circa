import AppKit
import BrowserCore
import ChromiumEngine

/// Confined real-engine qualification; no global input or system clipboard access.
@MainActor
enum OrbitTabErgonomicsProbe {
    static let bundleID = "lab.orbit.orbit.tab-ergonomics"

    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == bundleID,
              let configuration = activeSiteSessionConfiguration(), configuration.syntheticGuard != nil,
              configuration.usesMockKeychain, let window = owner.window,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
            && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }

    static func run(_ owner: OrbitWindowController, root: URL, command: [String: String]) async -> [String: Any] {
        guard owns(owner), let window = owner.window, let base = command["base"].flatMap(URL.init(string:)),
              base.scheme == "http", base.host == "127.0.0.1", let registry = owner.palette.registry else { return ["refused": true] }
        func stage(_ name: String) { try? name.write(to: root.appendingPathComponent("tabs-stage.txt"), atomically: true, encoding: .utf8) }
        stage("start")
        owner.palette.dismiss()
        window.makeKey()
        owner.focusSelectedDocument()
        var checks: [String: Any] = ["pid": getpid(), "offscreen": true]
        owner.palette.showsSearchSuggestions = false
        owner.session.openTab(url: base.appendingPathComponent("first"))
        await owner.session.waitForPendingCommands()
        guard let original = owner.session.selectedSurface else { return checks }
        await load(original)
        stage("first-loaded")
        original.navigate(to: base.appendingPathComponent("second"))
        await load(original)
        original.navigate(to: base.appendingPathComponent("third"))
        await load(original)
        original.goBack()
        await load(original)
        stage("history-ready")
        let history = original.nativePageServices?.navigationHistory()
        window.contentView?.layoutSubtreeIfNeeded()
        func click(_ view: NSView, flags: NSEvent.ModifierFlags = [], count: Int = 1, point: NSPoint? = nil) -> Bool {
            guard owns(owner), let event = NSEvent.mouseEvent(with: .leftMouseDown,
                location: view.convert(point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
                modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) else { return false }
            return registry.handleInputEvent(event)
        }
        let before = owner.session.snapshot!.tabs.count
        checks["commandReloadConsumed"] = click(owner.reloadButton, flags: .command)
        await settle(owner)
        stage("duplicate-adopted")
        if let surface = owner.session.selectedSurface { await load(surface) }
        checks["duplicate"] = owner.session.snapshot!.tabs.count == before + 1 && owner.session.selectedSurface !== original
            && owner.session.selectedSurface?.currentURL == original.currentURL
        if let duplicate = owner.session.selectedSurface, duplicate !== original {
            let copied = duplicate.nativePageServices?.navigationHistory()
            checks["duplicateHistory"] = history != nil && copied?.entries.map(\.url) == history?.entries.map(\.url)
                && copied?.currentIndex == history?.currentIndex
            duplicate.goForward()
            await load(duplicate)
            checks["duplicateForward"] = duplicate.currentURL?.path == "/third"
            checks["duplicateIndependent"] = original.currentURL?.path == "/second"
        }
        stage("history-checked")
        let list = owner.sidebar.page.list
        checks["emptyDoubleClick"] = click(list, count: 2, point: NSPoint(x: 100, y: list.bounds.maxY - 12))
        try? await Task.sleep(for: .milliseconds(180))
        checks["newTabCommand"] = owner.palette.isPresented
        owner.palette.dismiss()
        stage("new-tab-checked")
        let selected = owner.session.organization!.selectedTab!
        let copySourceHistory = owner.session.selectedSurface?.nativePageServices?.navigationHistory()
        let folderTask = owner.session.createFolder(title: "Synthetic folder", at: .init(.pinned(owner.session.snapshot!.activeSpaceID)))
        guard let folder = await folderTask.value else { return checks }
        await owner.session.waitForPendingCommands()
        let payload = SidebarDragPayload(sourceWindow: owner.id, spaceID: owner.session.snapshot!.activeSpaceID,
            profileID: original.profileID, nodes: [.tab(selected.id)], rowCount: 1, grabOffsetX: 0)
        guard owns(owner) else { return checks }
        owner.sidebar.onCopyDrop?(payload, .init(.folder(folder)))
        await settle(owner)
        stage("copy-adopted")
        checks["copyOriginalRetained"] = owner.session.organization?.tab(selected.id) != nil
            && owner.session.organization?.selectedTab?.id != selected.id
            && owner.session.organization?.location(of: .tab(owner.session.organization!.selectedTab!.id))?.1 == [folder]
        let copyHistory = owner.session.selectedSurface?.nativePageServices?.navigationHistory()
        checks["copyHistory"] = copySourceHistory != nil && copyHistory?.entries.map(\.url) == copySourceHistory?.entries.map(\.url)
            && copyHistory?.currentIndex == copySourceHistory?.currentIndex
        guard owns(owner) else { return checks }
        owner.sidebar.onTextDrop?(base.appendingPathComponent("dropped").absoluteString, .init(.today(owner.session.snapshot!.activeSpaceID)))
        await owner.session.waitForPendingCommands()
        if let surface = owner.session.selectedSurface { await load(surface) }
        checks["linkDrop"] = owner.session.selectedSurface?.currentURL?.path == "/dropped"
        stage("drop-checked")
        owner.tabSwitcher.controlIsHeld = { true }
        guard owns(owner) else { return checks }
        owner.tabSwitcher.cycle(holding: .control)
        let highlighted = owner.tabSwitcher.model.highlightedID
        func key(_ character: String, flags: NSEvent.ModifierFlags, code: UInt16) -> Bool {
            guard owns(owner), let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else { return false }
            return registry.handleInputEvent(event)
        }
        checks["controlW"] = key("w", flags: .control, code: 0)
        await owner.session.waitForPendingCommands()
        checks["highlightClosed"] = !owner.session.snapshot!.tabs.contains { $0.occurrenceID == highlighted }
        guard owns(owner) else { return checks }
        checks["backtick"] = registry.resolve(.init(key: "`", modifiers: .control)) == .tabSwitcherBackward
            && registry.dispatch(.tabSwitcherBackward, origin: .keyboard)
        guard owns(owner) else { return checks }
        owner.tabSwitcher.cancel()
        stage("switcher-checked")
        owner.focusSelectedDocument()
        if let surface = owner.session.selectedSurface {
            surface.navigate(to: base.appendingPathComponent("slow"))
            await loading(surface)
            checks["escape"] = key("\u{1b}", flags: [], code: 53)
            await owner.session.waitForPendingCommands()
            try? await Task.sleep(for: .milliseconds(100))
            checks["escapeStopped"] = !surface.navigationState.isLoading
            surface.navigate(to: base.appendingPathComponent("slow-again"))
            await loading(surface)
            checks["doubleReload"] = click(owner.reloadButton, count: 2)
            await owner.session.waitForPendingCommands()
            try? await Task.sleep(for: .milliseconds(100))
            checks["doubleReloadStopped"] = !surface.navigationState.isLoading
        }
        stage("stop-checked")
        let firstSpace = owner.session.snapshot!.activeSpaceID
        owner.session.createSpace(name: "Synthetic second", profileID: original.profileID)
        await owner.session.waitForPendingCommands()
        let secondSpace = owner.session.snapshot!.activeSpaceID
        for button in [3, 4] {
            guard owns(owner), let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!),
                  let event = NSEvent(cgEvent: cg) else { return checks }
            checks["sideButton\(button)"] = BrowserTabErgonomics.handle(event, in: owner)
            await owner.session.waitForPendingCommands()
        }
        checks["spaceCycle"] = firstSpace != secondSpace && owner.session.snapshot!.activeSpaceID == secondSpace
        owner.session.openTab(url: base.appendingPathComponent("review"))
        await owner.session.waitForPendingCommands()
        if let surface = owner.session.selectedSurface { await load(surface) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard owns(owner), let rootView = window.contentView else { return checks }
            window.appearance = NSAppearance(named: appearance)
            rootView.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(200))
            if let bitmap = rootView.bitmapImageRepForCachingDisplay(in: rootView.bounds) {
                rootView.cacheDisplay(in: rootView.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("tabs-\(name).png"))
            }
        }
        stage("done")
        return checks
    }

    private static func settle(_ owner: OrbitWindowController) async {
        for _ in 0..<20 { await owner.session.waitForPendingCommands(); await Task.yield() }
        try? await Task.sleep(for: .milliseconds(180))
        await owner.session.waitForPendingCommands()
    }

    private static func load(_ surface: ChromiumSurface) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        repeat { try? await Task.sleep(for: .milliseconds(20)) }
        while (!surface.isReady || surface.navigationState.isLoading) && ProcessInfo.processInfo.systemUptime < deadline
    }
    private static func loading(_ surface: ChromiumSurface) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !surface.navigationState.isLoading && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
