import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
@_spi(Testing) import ChromiumEngine

@MainActor
private final class GmailLoopbackSession: BrowserGmailWebSession {
    let engine: ChromiumBrowserEngine
    let origin: URL
    var requests = 0
    init(engine: ChromiumBrowserEngine, origin: URL) { self.engine = engine; self.origin = origin }
    func gmailInbox(profileID: ProfileID, account: BrowserGmailAccount) async throws -> BrowserGmailInbox {
        requests += 1
        return try await engine.gmailInboxFixture(profileID: profileID, origin: origin)
    }
}

/// Confined inbox fixture: only invented XML and loopback cookies enter the acceptance run.
@MainActor
enum OrbitGmailProbe {
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
        func click(_ target: NSView) -> Bool {
            guard owns(), NSApp.isActive, window.isKeyWindow, target.window === window else { return false }
            let point = target.convert(.init(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard owns(), let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
                NSApp.sendEvent(event)
            }
            return true
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        do {
            owner.palette.dismiss()
            window.setFrame(.init(x: 100, y: 100, width: 1100, height: 760), display: true)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            await wait({ NSApp.isActive && window.isKeyWindow }, seconds: 1)
            window.appearance = NSAppearance(named: command["appearance"] == "dark" ? .darkAqua : .aqua)
            let source = GmailLoopbackSession(engine: owner.engine, origin: base)
            owner.favorites.shutdown(); owner.favorites.grid.removeFromSuperview()
            owner.favorites = BrowserFavoritesController(owner: owner, gmailSession: source)
            owner.favorites.install(); owner.favorites.bind(to: application.commands.registry)
            owner.session.openTab(url: base.appendingPathComponent("seed"))
            await settle()
            guard let surface = owner.session.selectedSurface else { return ["missingSurface": true] }
            await wait { !surface.navigationState.isLoading && surface.navigationState.committedURL?.path == "/seed" }
            guard let id = owner.session.organization?.selectedTab?.id,
                  let profile = owner.session.activeProfileID else { return ["missingTab": true] }
            owner.session.addToFavorites([id]); await settle()
            owner.session.editPinnedURL(id, to: URL(string: "https://mail.google.com/mail/u/0/")!); await settle()
            owner.favorites.render()
            let account = BrowserGmailAccount(url: URL(string: "https://mail.google.com/mail/u/0/")!)!
            await wait({ owner.favorites.gmail.states[account]?.inbox != nil }, seconds: 12)
            let inbox = owner.favorites.gmail.states[account]?.inbox
            checks["profileCookieFeed"] = inbox?.unreadCount == 3 && inbox?.messages.count == 3
            checks["decodedText"] = inbox?.messages.first?.subject == "One & Two" && inbox?.messages.first?.summary.hasPrefix("Plain <safe> text") == true
            guard let tile = owner.favorites.grid.tiles.first(where: { $0.item.tab.id == id }) else { return ["missingTile": true] }
            checks["badgeCount"] = tile.item.gmailUnreadCount == 3 && tile.item.showsGmailBadge
            let selected = owner.session.organization?.selectedTab?.id
            let responder = window.firstResponder
            guard owns(), let hover = NSEvent.enterExitEvent(with: .mouseEntered, location: tile.convert(.zero, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, trackingNumber: 0, userData: nil) else { return ["hoverRefused": true] }
            tile.mouseEntered(with: hover)
            await wait { owner.favorites.gmailPreview.isPresented }
            checks["hoverPreview"] = owner.favorites.gmailPreview.isPresented
            checks["hoverKeepsSelection"] = owner.session.organization?.selectedTab?.id == selected
            checks["hoverKeepsResponder"] = window.firstResponder === responder
            capture("gmail-preview")
            let rows = views(owner.favorites.gmailPreview.view).filter { $0.accessibilityRole() == .button && !($0 is NSButton) }
            checks["threeNativeRows"] = rows.count == 3
            let dates = rows.flatMap { $0.subviews.compactMap { $0 as? NSTextField } }.filter { $0.alignment == .right }
            checks["datesFit"] = dates.count == 3 && dates.allSatisfy { field in
                guard let font = field.font, let cell = field.cell else { return false }
                let width = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
                return !field.stringValue.isEmpty && cell.drawingRect(forBounds: field.bounds).width >= ceil(width)
            }
            if let first = rows.first {
                checks["messageNativeClick"] = click(first)
                await settle()
                checks["messageUsesAccount"] = surface.currentURL?.absoluteString == account.messageURL(id: "abcdef")?.absoluteString
            }
            owner.favorites.gmailPreview.dismiss()
            // Restore the harmless loopback document while retaining the favorite's home identity.
            surface.navigate(to: base.appendingPathComponent("seed"))
            await wait { !surface.navigationState.isLoading && surface.navigationState.committedURL?.path == "/seed" }
            owner.favorites.render()
            if let current = owner.favorites.grid.tiles.first(where: { $0.item.tab.id == id }), owns() {
                current.mouseEntered(with: hover)
                await wait { owner.favorites.gmailPreview.isPresented }
                if let button = views(owner.favorites.gmailPreview.view).compactMap({ $0 as? NSButton }).first {
                    checks["composeNativeClick"] = click(button)
                    await settle()
                    checks["composeUsesAccount"] = surface.currentURL == account.composeURL
                }
            }
            owner.favorites.gmailPreview.dismiss()
            if let settings = owner.settingsPreferences?.runtime {
                let menu = owner.favorites.contextMenu(for: id)
                let item = menu?.items.first(where: { $0.title == uiText("Show Unread Badge") })
                checks["badgeMenuDefault"] = item?.state == .on
                if owns(), let item, let target = item.target as? NSObject, let action = item.action { target.perform(action, with: item) }
                await wait { settings.document.profile(profile).hiddenGmailBadges.contains(id) }
                owner.favorites.render()
                checks["badgeSettingSaved"] = settings.document.profile(profile).hiddenGmailBadges.contains(id)
                checks["badgeHidden"] = owner.favorites.grid.tiles.first(where: { $0.item.tab.id == id })?.item.showsGmailBadge == false
            }
            surface.navigate(to: base.appendingPathComponent("seed"))
            await wait { !surface.navigationState.isLoading && surface.navigationState.committedURL?.path == "/seed" }
            if let space = owner.session.organization?.spaceID {
                owner.session.moveItems([.tab(id)], to: .init(.pinned(space), position: .end))
                await settle(); owner.favorites.render()
                try? await Task.sleep(for: .milliseconds(500))
                if let row = owner.sidebar.page.list.row(for: .tab(id)) as? SidebarTabRow {
                    let menu = owner.makeSidebarContextMenu(for: [.tab(id)])
                    let badge = menu?.menu.items.first { $0.title == uiText("Show Unread Badge") }
                    checks["pinnedBadgePreference"] = badge?.state == .off
                    if owns(), let badge, let action = badge.action {
                        withExtendedLifetime(menu?.owner) { (badge.target as? NSObject)?.perform(action, with: badge) }
                    }
                    await wait { owner.settingsPreferences?.runtime.document.profile(profile).hiddenGmailBadges.contains(id) == false }
                    owner.favorites.render(); window.contentView?.layoutSubtreeIfNeeded()
                    checks["pinnedUnreadDot"] = row.subviews.contains { $0.identifier?.rawValue == "gmail-unread" && !$0.isHidden && $0.frame.width == 6 }
                    if owns() { row.mouseEntered(with: hover) }
                    await wait { owner.favorites.gmailPreview.isPresented }
                    checks["pinnedHoverPreview"] = owner.favorites.gmailPreview.isPresented
                    capture("gmail-pinned")
                    owner.favorites.gmailPreview.dismiss()
                }
            }
            let otherProfile = await environment.store.createProfile(name: "Synthetic isolated inbox")
            do { _ = try await owner.engine.gmailInboxFixture(profileID: otherProfile, origin: base); checks["otherProfileSignedOut"] = false }
            catch BrowserGmailPreviewError.signedOut { checks["otherProfileSignedOut"] = true }
            catch { checks["otherProfileSignedOut"] = false }
            let newSpace = try await environment.store.createSpace(name: "Synthetic empty context", profileID: otherProfile)
            owner.session.activateSpace(newSpace); await settle(); owner.favorites.render()
            checks["profileSwitchClearsMail"] = owner.favorites.gmail.states.isEmpty && !owner.favorites.gmailPreview.isPresented
            capture("gmail-cleared")
        } catch { checks["unexpectedError"] = false }
        return ["checks": checks, "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "pid": getpid()]
    }
}
