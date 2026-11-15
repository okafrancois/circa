import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
@_spi(Testing) import ChromiumEngine

@MainActor
private final class CalendarLoopbackSession: BrowserCalendarWebSession {
    let engine: ChromiumBrowserEngine
    let origin: URL
    var requests = 0
    init(engine: ChromiumBrowserEngine, origin: URL) { self.engine = engine; self.origin = origin }
    func calendarAgenda(profileID: ProfileID, account: BrowserCalendarWebAccount, day: Date, timeZone: TimeZone) async throws -> BrowserCalendarWebAgenda {
        requests += 1
        return try await engine.calendarAgendaFixture(profileID: profileID, account: account, day: day, timeZone: timeZone, origin: origin)
    }
}

/// Confined calendar fixture: invented HTML and loopback session cookies only.
@MainActor
enum OrbitCalendarProbe {
    static func run(_ application: OrbitApplication, environment: OrbitEnvironment, owner: OrbitWindowController,
                    base: URL, root: URL, command: [String: String]) async -> [String: Any] {
        func owns() -> Bool {
            guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.window-freeze",
                  Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true,
                  activeSyntheticDataGuard() != nil, let window = owner.window, window.isVisible,
                  let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
            return windows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        }
        guard owns(), let window = owner.window, base.scheme == "http", base.host == "127.0.0.1", base.port != nil else { return ["refused": true] }
        var checks: [String: Bool] = [:]
        func settle() async {
            await owner.session.waitForPendingCommands()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func wait(_ condition: () -> Bool, seconds: TimeInterval = 5) async {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }
        func capture(_ name: String) {
            guard owns(), let content = window.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + ".png"))
        }
        do {
            owner.palette.dismiss()
            NSApp.setActivationPolicy(.accessory)
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.level = .floating
            window.orderFrontRegardless()
            window.setFrame(.init(x: 100, y: 100, width: 1100, height: 760), display: true)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            await wait({ NSApp.isActive && window.isKeyWindow }, seconds: 1)
            window.appearance = NSAppearance(named: command["appearance"] == "dark" ? .darkAqua : .aqua)
            let source = CalendarLoopbackSession(engine: owner.engine, origin: base)
            owner.favorites.shutdown(); owner.favorites.grid.removeFromSuperview()
            owner.favorites = BrowserFavoritesController(owner: owner, calendarSession: source)
            owner.favorites.install(); owner.favorites.bind(to: application.commands.registry)
            owner.session.openTab(url: base.appendingPathComponent("seed"))
            await settle()
            guard let surface = owner.session.selectedSurface else { return ["missingSurface": true] }
            await wait { !surface.navigationState.isLoading && surface.navigationState.committedURL?.path == "/seed" }
            guard let id = owner.session.organization?.selectedTab?.id else { return ["missingTab": true] }
            owner.session.addToFavorites([id]); await settle()
            owner.session.editPinnedURL(id, to: URL(string: "https://calendar.google.com/calendar/u/0/r")!); await settle()
            owner.favorites.render()
            let account = BrowserCalendarWebAccount(url: URL(string: "https://calendar.google.com/calendar/u/0/r")!)!
            owner.palette.dismiss()
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            await wait({ NSApp.isActive && window.isKeyWindow }, seconds: 2)
            owner.favorites.calendar.refresh(account)
            await wait({ owner.favorites.calendar.agendas[account] != nil }, seconds: 12)
            let agenda = owner.favorites.calendar.agendas[account]
            checks["profileCookieAgenda"] = agenda?.events.count == 3
            checks["startOnlyFallback"] = agenda?.events.allSatisfy { $0.end == nil && $0.joinURL == nil } == true
            for path in ["notes", "tasks"] {
                owner.session.openTab(url: base.appendingPathComponent(path)); await settle()
                if let extra = owner.session.organization?.selectedTab?.id { owner.session.addToFavorites([extra]); await settle() }
            }
            owner.session.openTab(url: base.appendingPathComponent("seed")); await settle()
            owner.palette.dismiss()
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            await wait({ NSApp.isActive && window.isKeyWindow && !owner.palette.isPresented }, seconds: 2)
            owner.favorites.render(); window.contentView?.layoutSubtreeIfNeeded()
            guard let tile = owner.favorites.grid.tiles.first(where: { $0.item.tab.id == id }) else { return ["missingTile": true] }
            checks["countdown"] = tile.item.calendarCountdown != nil
            let selected = owner.session.organization?.selectedTab?.id
            let responder = window.firstResponder
            try? Data(String(window.windowNumber).utf8).write(to: root.appendingPathComponent("calendar-window.txt"))
            // The harness starts its window-only recorder before this fixed hover sequence.
            try? await Task.sleep(for: .seconds(2))
            // Window recording may activate its own controls; restore only our verified window.
            guard owns() else { return ["ownershipLost": true] }
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            owner.palette.dismiss()
            await wait({ NSApp.isActive && window.isKeyWindow }, seconds: 2)
            checks["hoverWindowKey"] = window.isKeyWindow
            checks["hoverApplicationActive"] = NSApp.isActive
            checks["hoverPermitted"] = owner.favorites.calendarPreview.permitted(tile, tile.item.tab, account)
            checks["hoverTileVisible"] = !tile.isHiddenOrHasHiddenAncestor && !tile.visibleRect.isEmpty
            checks["hoverAgendaFresh"] = owner.favorites.calendar.agendas[account]?.isFresh(at: Date()) == true
            guard owns(), let hover = NSEvent.enterExitEvent(with: .mouseEntered, location: tile.convert(.zero, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, trackingNumber: 0, userData: nil) else { return ["hoverRefused": true] }
            let began = ProcessInfo.processInfo.systemUptime
            tile.mouseEntered(with: hover)
            await wait { owner.favorites.calendarPreview.isPresented }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            try? Data(String(elapsed).utf8).write(to: root.appendingPathComponent("calendar-hover-seconds.txt"))
            checks["hoverDelay"] = elapsed >= 0.28 && elapsed < 0.5
            checks["hoverPreview"] = owner.favorites.calendarPreview.isPresented
            checks["hoverKeepsSelection"] = owner.session.organization?.selectedTab?.id == selected
            checks["hoverKeepsResponder"] = window.firstResponder === responder
            try? await Task.sleep(for: .milliseconds(120))
            capture("calendar-preview")
            try? await Task.sleep(for: .seconds(3))
            if owns(), let leave = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 2, trackingNumber: 0, userData: nil) { tile.mouseExited(with: leave) }
            try? await Task.sleep(for: .milliseconds(300))
            checks["leaveDismisses"] = !owner.favorites.calendarPreview.isPresented
            capture("calendar-countdown")
            let requests = source.requests
            owner.favorites.calendar.refresh(account)
            checks["refreshBudget"] = requests == source.requests
            let otherProfile = await environment.store.createProfile(name: "Synthetic isolated calendar")
            do { _ = try await owner.engine.calendarAgendaFixture(profileID: otherProfile, account: account, day: Date(), timeZone: .current, origin: base); checks["profileIsolation"] = false }
            catch { checks["profileIsolation"] = true }
            let newSpace = try await environment.store.createSpace(name: "Synthetic empty context", profileID: otherProfile)
            owner.session.activateSpace(newSpace); await settle(); owner.favorites.render()
            checks["profileSwitchClearsAgenda"] = owner.favorites.calendar.agendas.isEmpty && !owner.favorites.calendarPreview.isPresented
        } catch { checks["unexpectedError"] = false }
        return ["checks": checks, "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "pid": getpid()]
    }
}
