import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

extension BrowserScriptingController {
    /// Inventory is read in command order; inactive Spaces do not need renderer creation.
    func capture<Engine: BrowserEngine>(_ owner: BrowserWindowController<Engine>, environment: BrowserEnvironment<Engine>) async -> CircaScriptWindow {
        let session = owner.session!
        await session.waitForPendingCommands()
        let document = await environment.store.sessionDocument()
        let window = CircaScriptWindow(id: owner.id.uuidString, mode: owner.isPrivateWindow ? "incognito" : "normal",
            scripting: self, isFocused: { [weak owner] in owner?.window?.isKeyWindow == true && NSApp.isActive },
            title: { [weak owner] in owner?.window?.title ?? "" })
        window.focus = { [weak owner] in owner?.window?.makeKeyAndOrderFront(nil); NSApp.activate() }
        window.close = { [weak owner] in owner?.window?.performClose(nil) }
        window.selectedTabID = { [weak session] in session?.organization?.selectedTab?.id.rawValue.uuidString }
        window.selectedSpaceID = { [weak session] in session?.snapshot?.activeSpaceID.rawValue.uuidString }
        window.makeTab = { [weak owner, weak self] url, spaceID in
            guard let self else { throw BrowserScriptError.unavailable }
            try validateNavigation(url)
            guard let owner, owner.acceptsCommands else { throw BrowserScriptError.unavailable }
            if let spaceID, let uuid = UUID(uuidString: spaceID) { session.activateSpace(SpaceID(uuid)) }
            guard let tab = await session.openTabForDelivery(url: url).value else { throw BrowserScriptError.unavailable }
            return tab.id.rawValue.uuidString
        }
        let standalone = session.snapshot?.isStandalone == true
        let spaces = document.spaces.filter { !standalone || $0.id == session.snapshot?.activeSpaceID }
        for record in spaces {
            let space = CircaScriptSpace(id: record.id.rawValue.uuidString, title: record.name, window: window)
            space.focus = { [weak owner, weak window] in
                guard let owner, owner.acceptsCommands else { throw BrowserScriptError.unavailable }
                session.activateSpace(record.id); await session.waitForPendingCommands(); window?.focus()
            }
            let sections = document.organization.spaces.first { $0.spaceID == record.id }
            let favorites = document.organization.favorites.first { $0.profileID == record.profileID }?.items ?? []
            let local = document.windows.first { $0.id == session.snapshot?.id }?.standalone
            let pinned = standalone ? [] : sections?.pinned ?? []
            let today = local?.nodes ?? sections?.today ?? []
            func flatten(_ nodes: [BrowserOrganizationNode], location: String) -> [(TabID, String)] {
                nodes.flatMap { node in
                    switch node {
                    case .tab(let id): [(id, location)]
                    case .folder(let id): flatten(document.organization.folders.first { $0.id == id }?.children ?? [], location: location)
                    case .split(let id): (((local?.splits ?? []) + document.organization.splits).first { $0.id == id }?.tabIDs ?? []).map { ($0, location) }
                    }
                }
            }
            for (id, location) in flatten(standalone ? [] : favorites, location: "topApp") + flatten(pinned, location: "pinned") + flatten(today, location: "unpinned") {
                guard let tab = ((local?.tabs ?? []) + document.organization.tabs).first(where: { $0.id == id }) else { continue }
                let live = session.organizationTab(id)
                let surface = live?.occurrenceID.flatMap { session.surface(for: $0) }
                let wrapper = CircaScriptTab(id: id.rawValue.uuidString, title: live?.title ?? tab.customTitle ?? tab.pageTitle ?? "",
                    url: (surface?.currentURL ?? live?.url ?? tab.url).absoluteString, location: location,
                    loading: surface?.navigationState.isLoading ?? false, space: space)
                wrapper.action = { [weak owner, weak window, weak self] action in
                    guard let owner, owner.acceptsCommands else { throw BrowserScriptError.unavailable }
                    if case .close = action {
                        session.activateSpace(record.id); session.closeTabs([id]); await session.waitForPendingCommands(); return nil
                    }
                    session.activateSpace(record.id); session.selectTab(id); await session.waitForPendingCommands()
                    guard let surface = session.selectedSurface, session.organization?.selectedTab?.id == id else { throw BrowserScriptError.unavailable }
                    switch action {
                    case .select: window?.focus()
                    case .close: break
                    case .reload: surface.reload()
                    case .back: if let url = surface.goBack() { session.updateDestination(for: surface, to: url) }
                    case .forward: if let url = surface.goForward() { session.updateDestination(for: surface, to: url) }
                    case .stop: surface.stopLoading()
                    case .navigate(let url):
                        guard let self else { throw BrowserScriptError.unavailable }
                        try validateNavigation(url)
                        surface.navigate(to: url); session.updateDestination(for: surface, to: url)
                    case .javascript(let script):
                        guard self?.allowsJavaScript() == true else { throw BrowserScriptError.javaScriptDisabled }
                        guard window?.canReadPrivateContent == true else { throw BrowserScriptError.privateContent }
                        guard let probe = environment.engine as? any BrowserEngineConformanceProbe<Engine.Surface> else { throw BrowserScriptError.unsupported }
                        return try await probe.evaluateScript(script, in: surface)
                    }
                    await session.waitForPendingCommands()
                    return nil
                }
                space.appleScriptTabs.append(wrapper)
            }
            window.appleScriptSpaces.append(space)
        }
        return window
    }
}

extension OrbitApplication {
    func configureScripting(_ scripting: BrowserScriptingController) {
        scripting.allowsJavaScript = { [weak self] in self?.environment?.settings.document.allowJavaScriptFromAppleEvents == true }
        scripting.refresh = { [weak self, weak scripting] in
            guard let self, let scripting else { return }
            await waitForScriptingStartup()
            await windows.waitForPendingCommands()
            var result: [CircaScriptWindow] = []
            let ordered = windows.windows.values.sorted {
                if $0.id == windows.selectedWindowID { return true }
                if $1.id == windows.selectedWindowID { return false }
                return $0.id.uuidString < $1.id.uuidString
            }
            for owner in ordered where !owner.session.isClosed {
                if let environment = privateWindows[owner.id]?.environment ?? environment {
                    result.append(await scripting.capture(owner, environment: environment))
                }
            }
            scripting.windows = result
        }
        scripting.createWindow = { [weak self, weak scripting] mode in
            guard let self, let scripting, !isPreparingToQuit else { throw BrowserScriptError.unavailable }
            if mode == "incognito" { createPrivateCommandWindow(); await waitForPrivateWindowCommands() }
            else if mode == "normal" { windows.newWindow() }
            else { throw BrowserScriptError.unsupported }
            await scripting.refresh()
            guard let window = scripting.windows.first else { throw BrowserScriptError.unavailable }
            return window
        }
    }
}
