import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

@MainActor
enum BrowserQuickWindowCommands {
    nonisolated static let definitions: [BrowserCommandDefinition] = [
        .init(id: .closeQuickWindow, title: BrowserText.string("Close Little Circa"), menu: "File", shortcuts: [.init(key: "w", modifiers: .command)], scope: .quickWindow, requirement: .window, owner: "LITTLE", sources: ["Browser command"]),
        .init(id: .focusQuickWindowAddress, title: BrowserText.string("Search or Enter URL"), menu: "File", shortcuts: [.init(key: "l", modifiers: .command)], scope: .quickWindow, requirement: .window, owner: "LITTLE", sources: ["Browser command"]),
        .init(id: .reloadQuickWindow, title: BrowserText.string("Reload Little Circa"), menu: "View", shortcuts: [.init(key: "r", modifiers: .command)], scope: .quickWindow, requirement: .window, owner: "LITTLE", sources: ["Browser command"])
    ]

    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>,
        active: @escaping () -> BrowserQuickWindowWindowController<Engine>?,
        promote: @escaping (BrowserQuickWindowWindowController<Engine>) -> Void,
        chooseSpace: @escaping (BrowserQuickWindowWindowController<Engine>) -> Void) {
        registry.registerScopeProvider("little-orbit", priority: 500) { _ in active() == nil ? nil : .quickWindow }
        func command(_ id: BrowserCommandID, _ action: @escaping (BrowserQuickWindowWindowController<Engine>) -> Void) {
            try! registry.registerApplication(id) { if let controller = active() { action(controller) } }
            registry.registerPrerequisite(id) { _, _ in
                guard let controller = active() else { return false }
                return !controller.isClosed && !controller.isPromotionInProgress
            }
        }
        command(.closeQuickWindow) { $0.window?.performClose(nil) }
        command(.focusQuickWindowAddress) { $0.focusAddress() }
        try! registry.registerScopedApplication(.newTab, scope: .quickWindow, validate: {
            active()?.acceptsCommands == true
        }) { active()?.focusAddress() }
        command(.reloadQuickWindow) { controller in
            guard let surface = controller.surface, controller.container.owns(surface) else { return }
            surface.reload()
        }
        func page(_ id: BrowserCommandID, enabled: @escaping (BrowserQuickWindowWindowController<Engine>, Engine.Surface) -> Bool = { _, _ in true },
                  action: @escaping (BrowserQuickWindowWindowController<Engine>, Engine.Surface) -> Void) {
            try! registry.registerScopedApplication(id, scope: .quickWindow, validate: {
                guard let controller = active(), controller.acceptsCommands, let surface = controller.surface,
                      !surface.isDisposed, controller.owns(surface) else { return false }
                return enabled(controller, surface)
            }) {
                guard let controller = active(), controller.acceptsCommands, let surface = controller.surface,
                      controller.owns(surface) else { return }
                action(controller, surface)
            }
        }
        page(.forceRefreshThePage, enabled: { controller, _ in controller.engine.capabilities.contains(.cacheBypassingReload) }) { controller, surface in
            do { try surface.reloadIgnoringCache() } catch { NSSound.beep() }
        }
        page(.developerTools, enabled: { controller, _ in controller.engine.capabilities.contains(.devTools) }) { _, surface in
            try? surface.perform(.showDevTools)
        }
        page(.inspectElements, enabled: { controller, _ in controller.engine.capabilities.contains(.devTools) }) { _, surface in
            try? surface.perform(.inspectElements)
        }
        page(.javascriptConsole, enabled: { controller, _ in controller.engine.capabilities.contains(.devTools) }) { controller, surface in
            do { try surface.showDeveloperPanel(.console) } catch { NSSound.beep() }
        }
        page(.goBack, enabled: { _, surface in surface.navigationState.canGoBack }) { _, surface in surface.goBack() }
        page(.goForward, enabled: { _, surface in surface.navigationState.canGoForward }) { _, surface in surface.goForward() }
        page(.find) { controller, _ in controller.showFind() }
        page(.findNext) { controller, _ in controller.findSession.next() }
        page(.findPrevious) { controller, _ in controller.findSession.previous() }
        page(.zoomIn) { _, surface in surface.performZoom(.increase) }
        page(.zoomOut) { _, surface in surface.performZoom(.decrease) }
        page(.zoomToActualSize) { _, surface in surface.performZoom(.reset) }
        page(.copyURL, enabled: { _, surface in surface.navigationState.url != nil }) { controller, _ in controller.copyURL() }
        page(.share, enabled: { _, surface in surface.navigationState.url != nil }) { controller, surface in
            if let url = surface.navigationState.url { controller.shareURL(url) }
        }
        page(.stopLoading, enabled: { _, surface in surface.navigationState.isLoading }) { _, surface in surface.stopLoading() }
        page(.print, enabled: { controller, _ in controller.canPrint }) { controller, _ in controller.printPage() }
        page(.showSiteControls, enabled: { controller, _ in controller.siteControls.canShow }) { controller, _ in controller.siteControls.show() }
        // Use the registry's actual binding in accessibility help, not a second shortcut literal.
        if let controller = active() {
            controller.promotionShortcut = { [weak registry] in registry?.definition(.promoteQuickWindow)?.shortcuts.first?.displayLabel }
        }
        command(.promoteQuickWindow, promote)
        command(.chooseQuickWindowSpace, chooseSpace)
    }
}
