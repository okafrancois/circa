import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Synthetic-only qualification of native menus and indexed Chromium history.
@MainActor
enum OrbitNavigationHistoryProbe {
    static let bundleID = "lab.orbit.orbit.nav-history-menu"
    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.infoDictionary?["OrbitUseMockKeychain"] as? Bool == true,
              let window = owner.window,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }
    private static func loaded(_ surface: ChromiumSurface, at url: URL) async -> Bool {
        for _ in 0..<200 {
            if surface.isReady, !surface.navigationState.isLoading, surface.nativePageServices?.committedURL() == url {
                try? await Task.sleep(for: .milliseconds(200))
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
    /// Exercises a foreign-window row projection in the actual product sidebar.
    private static func rowDecoration(_ owner: OrbitWindowController, base: URL, root: URL) async -> [String: Any] {
        guard let window = owner.window, owns(owner) else { return ["refused": true] }
        owner.session.openTab(url: base.appendingPathComponent("sidebar"))
        await owner.session.waitForQueuedCommands()
        guard let surface = owner.session.selectedSurface,
              await loaded(surface, at: base.appendingPathComponent("sidebar")),
              let id = owner.session.organization?.selectedTab?.id,
              let row = owner.sidebar.page.list.row(for: .tab(id)) as? SidebarTabRow else { return ["missingRow": true] }
        window.setFrameOrigin(NSPoint(x: 160, y: 140))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        var checks: [String: Any] = [:]
        for dark in [false, true] {
            guard owns(owner) else { return ["ownershipLost": true] }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var item = row.item
            item.isOpenInAnotherWindow = false
            row.update(item, depth: row.depth)
            row.layoutSubtreeIfNeeded()
            let ordinaryEnd = row.titleEnd
            let ordinaryImages = row.subviews.compactMap { $0 as? NSImageView }.count
            item.isOpenInAnotherWindow = true
            row.update(item, depth: row.depth)
            row.layoutSubtreeIfNeeded()
            let mode = dark ? "dark" : "light"
            checks[mode + "FullTitleWidth"] = abs(row.titleEnd - ordinaryEnd) < 0.01
            checks[mode + "NoAdditionalImage"] = row.subviews.compactMap { $0 as? NSImageView }.count == ordinaryImages
                && ordinaryImages == 1
            checks[mode + "ForeignStateRetained"] = row.item.isOpenInAnotherWindow
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
            guard owns(owner) else { return ["ownershipLost": true] }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), root.appendingPathComponent(mode + ".png").path]
            try? capture.run(); capture.waitUntilExit()
            checks[mode + "Captured"] = capture.terminationStatus == 0
        }
        return checks
    }
    private static func favoriteIcons(_ owner: OrbitWindowController, base: URL, root: URL) async -> [String: Any] {
        guard owns(owner), let window = owner.window else { return ["refused": true] }
        var ids: [TabID] = []
        for index in 0..<9 {
            owner.session.openTab(url: base.appendingPathComponent("icon-\(index)"))
            await owner.session.waitForQueuedCommands()
            guard let id = owner.session.organization?.selectedTab?.id else { return ["missingTab": true] }
            ids.append(id)
        }
        owner.session.addToFavorites(ids)
        await owner.session.waitForQueuedCommands()
        guard let surface = owner.session.selectedSurface,
              await loaded(surface, at: base.appendingPathComponent("icon-8")) else { return ["loadFailed": true] }
        try? await Task.sleep(for: .seconds(1))
        owner.favorites.render()
        window.setFrameOrigin(NSPoint(x: 160, y: 140))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        var items = owner.favorites.grid.items
        guard items.count == 9 else { return ["wrongTileCount": items.count] }
        for index in items.indices {
            let side = [16, 32, 64][index % 3]
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let bytes = bitmap.bitmapData else { return ["bitmapFailed": true] }
            bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * side)
            let inset = index >= 3 ? side / 4 : 0
            for y in inset..<(side - inset) { for x in inset..<(side - inset) {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = UInt8(40 + index * 22); bytes[offset + 1] = UInt8(200 - index * 14)
                bytes[offset + 2] = UInt8(90 + index * 17); bytes[offset + 3] = 255
            } }
            let image = NSImage(size: NSSize(width: side, height: side)); image.addRepresentation(bitmap)
            items[index].favicon = image
        }
        var checks: [String: Any] = [:]
        for dark in [false, true] {
            guard owns(owner) else { return ["ownershipLost": true] }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            owner.favorites.grid.render(items, profileID: owner.session.activeProfileID)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            let mode = dark ? "dark" : "light"
            checks[mode + "NineTiles"] = owner.favorites.grid.tiles.count == 9
            checks[mode + "CommonFrames"] = owner.favorites.grid.tiles.enumerated().allSatisfy { index, tile in
                tile.item.favicon === items[index].favicon && tile.subviews.compactMap { $0 as? FavoriteFaviconImageView }.first?.frame.size == NSSize(width: 20, height: 20)
            }
            let visibleSizes = owner.favorites.grid.tiles.compactMap { tile -> CGFloat? in
                guard let icon = tile.subviews.compactMap({ $0 as? FavoriteFaviconImageView }).first,
                      let bitmap = icon.bitmapImageRepForCachingDisplay(in: icon.bounds) else { return nil }
                icon.cacheDisplay(in: icon.bounds, to: bitmap)
                var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
                for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                } }
                let width = CGFloat(maxX - minX + 1) * 20 / CGFloat(bitmap.pixelsWide)
                let height = CGFloat(maxY - minY + 1) * 20 / CGFloat(bitmap.pixelsHigh)
                return max(width, height)
            }
            checks[mode + "CommonArtworkSize"] = visibleSizes.count == 9 && visibleSizes.allSatisfy { abs($0 - 20) <= 1 }
            guard owns(owner) else { return ["ownershipLost": true] }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), root.appendingPathComponent(mode + ".png").path]
            try? capture.run(); capture.waitUntilExit()
            checks[mode + "Captured"] = capture.terminationStatus == 0
        }
        return checks
    }
    /// Uses the real card callback with a staged display version and a non-installing fixture.
    private static func changelog(_ owner: OrbitWindowController, root: URL) async -> [String: Any] {
        guard owns(owner), let window = owner.window,
              let updater = owner.settingsPreferences?.runtime.updater else { return ["refused": true] }
        var installed = 0
        updater.fetchLatestVersion = { "27" }
        updater.installPendingUpdate = { installed += 1 }
        updater.prepared(version: "27", displayVersion: "0.60.3")
        guard await updater.validatePendingUpdate() else { return ["stagingFailed": true] }
        window.setFrameOrigin(NSPoint(x: 160, y: 140))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        var checks: [String: Any] = [:]
        for dark in [false, true] {
            guard owns(owner) else { return ["ownershipLost": true] }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // Ordinary synthetic bundles hide updater UI. Show this staged fixture explicitly.
            owner.sidebar.updateReady = true
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
            let mode = dark ? "dark" : "light"
            let card = owner.sidebar.updateCard
            checks[mode + "CardVisible"] = !card.isHidden && card.body.window === window
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), root.appendingPathComponent(mode + "-card.png").path]
            try? capture.run(); capture.waitUntilExit()
            checks[mode + "Captured"] = capture.terminationStatus == 0
            guard owns(owner), window.isKeyWindow, NSApp.isActive else { return ["inputRefused": true] }
            let point = card.body.convert(NSPoint(x: card.body.bounds.midX, y: card.body.bounds.midY), to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.05,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return ["eventFailed": true] }
            NSApp.postEvent(up, atStart: true)
            card.body.mouseDown(with: down)
            await owner.session.waitForQueuedCommands()
            let expected = OrbitReleaseNotes.versionURL("0.60.3")!
            checks[mode + "OpenedStagedNotes"] = owner.session.organization?.selectedTab?.url == expected
            checks[mode + "NoInstall"] = installed == 0 && updater.pendingVersion == "27"
            if let surface = owner.session.selectedSurface {
                checks[mode + "ChromiumLoaded"] = await loaded(surface, at: expected)
            }
        }
        return checks
    }
    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        guard owns(owner), let text = command["url"], let base = URL(string: text),
              base.host == "127.0.0.1", base.scheme == "http", let window = owner.window else { return ["refused": true] }
        if command["changelog"] == "1" { return await changelog(owner, root: root) }
        if command["favoriteIcons"] == "1" { return await favoriteIcons(owner, base: base, root: root) }
        if command["rows"] == "1" { return await rowDecoration(owner, base: base, root: root) }
        var result: [String: Any] = [:]
        let urls = ["first", "second", "third"].map { base.appendingPathComponent($0) }
        owner.session.openTab(url: urls[0])
        await owner.session.waitForQueuedCommands()
        guard let surface = owner.session.selectedSurface else { return ["missingSurface": true] }
        for (index, url) in urls.enumerated() {
            if index > 0 { surface.navigate(to: url) }
            guard await loaded(surface, at: url) else { return ["loadFailed": index] }
        }
        guard let api = surface.nativePageServices else { return ["missingAPI": true] }
        result["history"] = api.navigationHistory().flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        // Capture only owned native menu windows; no desktop or other application's pixels.
        func menu(_ button: BrowserNavigationGlyphButton, name: String, hold: Bool, choose: Int?) -> [String] {
            guard owns(owner) else { return [] }
            let factory = button.navigation.makeMenu
            var presentation: BrowserNavigationHistoryMenu?
            button.navigation.makeMenu = { presentation = factory?(); return presentation }
            defer { button.navigation.makeMenu = factory }
            let timer = Timer(timeInterval: hold ? button.navigation.hold.delay + 0.35 : 0.35, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard owns(owner), let menu = presentation?.menu else { return }
                    let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                    if let row = rows.first(where: {
                        ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                            && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0
                            && ($0[kCGWindowNumber as String] as? Int) != window.windowNumber
                    }), let number = row[kCGWindowNumber as String] as? Int {
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l", String(number), root.appendingPathComponent(name + ".png").path]
                        try? capture.run(); capture.waitUntilExit()
                    }
                    if let choose, menu.items.indices.contains(choose), owns(owner) { menu.performActionForItem(at: choose) }
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .common)
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: hold ? .leftMouseDown : .rightMouseDown,
                location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), owns(owner) else { return [] }
            if hold { button.mouseDown(with: event) } else { button.rightMouseDown(with: event) }
            timer.invalidate()
            return presentation?.menu.items.map(\.title) ?? []
        }
        if command["capture"] == "onscreen", let screen = NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 140,
                                           y: screen.visibleFrame.maxY - window.frame.height - 80))
        }
        defer { window.setFrameOrigin(NSPoint(x: -2000, y: -1200)) }
        NSApp.appearance = NSAppearance(named: .aqua)
        window.appearance = NSAppearance(named: .aqua)
        owner.refreshNavigation(for: surface)
        result["backLight"] = menu(owner.backButton, name: "back-light", hold: true, choose: 1)
        result["selectedFirst"] = await loaded(surface, at: urls[0])
        owner.refreshNavigation(for: surface)
        result["forwardLight"] = menu(owner.forwardButton, name: "forward-light", hold: false, choose: nil)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.appearance = NSAppearance(named: .darkAqua)
        result["forwardDark"] = menu(owner.forwardButton, name: "forward-dark", hold: true, choose: 1)
        result["selectedThird"] = await loaded(surface, at: urls[2])
        owner.refreshNavigation(for: surface)
        result["backDark"] = menu(owner.backButton, name: "back-dark", hold: false, choose: nil)
        let before = Set(owner.session.snapshot?.tabs.map(\.id) ?? [])
        let point = owner.backButton.convert(NSPoint(x: 5, y: 5), to: nil)
        if owns(owner), let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [.command],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
           let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [.command],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            let source = owner.backButton.navigation.nextEvent
            owner.backButton.navigation.nextEvent = { _ in up }
            if owns(owner) { owner.backButton.mouseDown(with: down) }
            owner.backButton.navigation.nextEvent = source
        }
        await owner.session.waitForQueuedCommands()
        let added = owner.session.snapshot?.tabs.filter { !before.contains($0.id) } ?? []
        result["commandOpenedBackground"] = added.count == 1 && added[0].url == urls[1]
            && owner.session.selectedSurface === surface && api.committedURL() == urls[2]
        let order = owner.session.organization?.tabNavigationItems ?? []
        if let source = owner.session.organization?.selectedTab?.id, let index = order.firstIndex(where: { $0.id == source }) {
            result["adjacent"] = order.indices.contains(index + 1) && order[index + 1].id == added.first?.id
        }
        result["pid"] = getpid()
        return result
    }
}
