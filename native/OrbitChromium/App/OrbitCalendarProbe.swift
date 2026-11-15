import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import UserNotifications
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
        let reminders = BrowserMeetingReminders.shared
        let originalSound = reminders.playSound, originalAuthorization = reminders.authorize, originalPost = reminders.post
        var soundCalls = 0, posts: [String] = []
        let authorization = BrowserNotificationAuthorization.shared
        let originalRequest = authorization.request
        var permissionRequests = 0, permissionError = 0
        authorization.request = {
            permissionRequests += 1
            do { return try await originalRequest() }
            catch { permissionError = (error as NSError).code; throw error }
        }
        reminders.playSound = { soundCalls += 1; originalSound() }
        // The standard acceptance never opens a system consent panel.
        reminders.authorize = command["notifications"] == "yes" ? originalAuthorization : { true }
        reminders.post = { id, title, minutes, sound in
            posts.append(id); await originalPost(id, title, minutes, sound)
        }
        defer {
            reminders.playSound = originalSound; reminders.authorize = originalAuthorization; reminders.post = originalPost
            authorization.request = originalRequest
        }
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
            NSApp.setActivationPolicy(command["notifications"] == "yes" ? .regular : .accessory)
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
            await wait { surface.navigationState.faviconImage != nil }
            if let pixels = surface.navigationState.faviconImage, let image = await pixels.nativeImage() {
                owner.favorites.icons.memoryCache.put(image, profile: surface.profileID,
                    home: URL(string: "https://calendar.google.com/calendar/r")!)
            }
            owner.session.editPinnedURL(id, to: URL(string: "https://calendar.google.com/calendar/r")!); await settle()
            if let profile = owner.session.organization?.profileID {
                try await owner.settingsPreferences?.runtime.updateProfile(profile) { $0.hiddenCalendarMeetingLinks.insert(id) }
            }
            owner.favorites.render()
            let account = BrowserCalendarWebAccount(url: URL(string: "https://calendar.google.com/calendar/u/0/r")!)!
            owner.palette.dismiss()
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            await wait({ NSApp.isActive && window.isKeyWindow }, seconds: 2)
            owner.favorites.calendar.refresh(account)
            await wait({ owner.favorites.calendar.agendas[account] != nil }, seconds: 12)
            let agenda = owner.favorites.calendar.agendas[account]
            checks["plainFavoriteBinding"] = owner.session.organization?.tab(id).map { owner.favorites.calendarPermitted($0, account) } == true
            checks["profileCookieAgenda"] = agenda?.events.count == 3
            checks["durationBinding"] = agenda?.events.map { $0.end?.timeIntervalSince($0.start) ?? 0 } == [2700, 3600, 5400]
            checks["meetingBinding"] = agenda?.events.filter { $0.joinURL != nil }.count == 2
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
            checks["calendarFavicon"] = tile.item.favicon != nil
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
            checks["reminderPreferenceHidden"] = owner.sidebar.calendarReminder.isHidden
            guard owns() else { return ["ownershipLost": true] }
            if let profile = owner.session.organization?.profileID {
                try await owner.settingsPreferences?.runtime.updateProfile(profile) { $0.hiddenCalendarMeetingLinks.remove(id) }
            }
            owner.favorites.render()
            try? await Task.sleep(for: .milliseconds(600))
            checks["reminder"] = !owner.sidebar.calendarReminder.isHidden
            checks["oneSoundCall"] = soundCalls == 1
            checks["noActiveBanner"] = posts.isEmpty
            owner.favorites.render()
            checks["refreshDoesNotRepeatSound"] = soundCalls == 1
            if let tab = owner.session.organization?.tab(id),
               let menu = owner.favorites.calendarMenu(tab, account: account, gear: false),
               let submenu = menu.items.first(where: { $0.title == uiText("Show Next Meeting Link") })?.submenu {
                checks["timingOptions"] = submenu.items.map(\.title) == [uiText("2 minutes before"), uiText("5 minutes before"), uiText("10 minutes before"), uiText("Never")]
                checks["fiveMinuteDefault"] = submenu.items.map(\.state) == [.off, .on, .off, .off]
                if let profile = owner.session.organization?.profileID {
                    for (index, time) in [(0, BrowserCalendarReminderTime.twoMinutes), (2, .tenMinutes), (3, .never), (1, .fiveMinutes)] {
                        guard owns() else { return ["ownershipLost": true] }
                        guard let fresh = owner.favorites.calendarMenu(tab, account: account, gear: false)?.items.first(where: { $0.title == uiText("Show Next Meeting Link") })?.submenu else { return ["missingTimingMenu": true] }
                        fresh.performActionForItem(at: index)
                        await wait { owner.settingsPreferences?.runtime.document.profile(profile).calendarReminderTime(for: id) == time }
                        checks["timingChoice-\(time.rawValue)"] = owner.settingsPreferences?.runtime.document.profile(profile).calendarReminderTime(for: id) == time
                    }
                    checks["settingChangesDoNotRepeatSound"] = soundCalls == 1
                }
            }
            capture("calendar-reminder")
            try? await Task.sleep(for: .seconds(1))
            guard owns() else { return ["ownershipLost": true] }
            owner.sidebar.calendarReminder.join.performClick(nil)
            await settle()
            checks["joinNormalTab"] = owner.session.organization?.selectedTab?.url == agenda?.events.first?.joinURL
            try? await Task.sleep(for: .milliseconds(600))
            capture("calendar-joined")
            try? await Task.sleep(for: .seconds(2))
            let staleJoin = owner.sidebar.calendarReminder.onJoin
            if command["notifications"] == "yes", let next = agenda?.events.dropFirst().first {
                // Move only the ephemeral test clock, keeping the verified agenda fresh.
                let moment = (agenda?.events.first?.start ?? Date()).addingTimeInterval(1)
                owner.favorites.calendar.now = { moment }
                guard owns() else { return ["ownershipLost": true] }
                NSApp.hide(nil)
                await wait({ NSApp.isHidden }, seconds: 1)
                checks["backgroundApplicationHidden"] = NSApp.isHidden
                owner.favorites.render()
                await wait({ !posts.isEmpty }, seconds: 8)
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                let report: [String: Any] = ["authorization": settings.authorizationStatus.rawValue,
                    "permissionRequests": permissionRequests, "permissionError": permissionError,
                    "postCalls": posts.count, "delivered": delivered.filter { posts.contains($0.request.identifier) }.count,
                    "soundCalls": soundCalls, "nextTitleIsSynthetic": next.title == "Design workshop"]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
                    try? data.write(to: root.appendingPathComponent("calendar-notification-result.json"))
                }
                NSApp.unhide(nil); window.deminiaturize(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                await wait({ window.isVisible && NSApp.isActive }, seconds: 1)
                if let identifier = posts.last {
                    let before = owner.session.organization?.selectedTab?.id
                    guard owns() else { return ["ownershipLost": true] }
                    checks["notificationJoinHandler"] = reminders.respond(identifier, join: true)
                    await settle()
                    checks["notificationJoinNormalTab"] = owner.session.organization?.selectedTab?.id != before && owner.session.organization?.selectedTab?.url == next.joinURL
                }
                owner.favorites.calendar.now = Date.init
            }
            let requests = source.requests
            owner.favorites.calendar.refresh(account)
            checks["refreshBudget"] = requests == source.requests
            let otherProfile = await environment.store.createProfile(name: "Synthetic isolated calendar")
            do { _ = try await owner.engine.calendarAgendaFixture(profileID: otherProfile, account: account, day: Date(), timeZone: .current, origin: base); checks["profileIsolation"] = false }
            catch { checks["profileIsolation"] = true }
            owner.favorites.calendar.now = { (agenda?.fetchedAt ?? Date()).addingTimeInterval(120) }
            checks["staleJoinRejected"] = staleJoin?() == false
            owner.favorites.calendar.now = Date.init
            owner.favorites.calendar.sessionChanged(account)
            checks["sessionJoinRejected"] = staleJoin?() == false
            let newSpace = try await environment.store.createSpace(name: "Synthetic empty context", profileID: otherProfile)
            owner.session.activateSpace(newSpace); await settle(); owner.favorites.render()
            checks["profileSwitchClearsAgenda"] = owner.favorites.calendar.agendas.isEmpty && !owner.favorites.calendarPreview.isPresented
        } catch { checks["unexpectedError"] = false }
        return ["checks": checks, "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "pid": getpid()]
    }
}
