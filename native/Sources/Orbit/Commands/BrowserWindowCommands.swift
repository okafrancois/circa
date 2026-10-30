import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Engine-independent production bindings, also exercised by the hidden integration tests.
@MainActor
enum BrowserWindowCommands {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>,
                                               commandKeyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
                                               pasteboardString: @escaping () -> String? = { NSPasteboard.general.string(forType: .string) }) {
        BrowserSiteCommands.install(in: registry)
        BrowserDailyCommands.install(in: registry)
        BrowserDiagnosticCommands.install(in: registry)
        BrowserBookmarkCommands.install(in: registry)
        OrbitShellCommands.install(in: registry)
        BrowserSwitcherCommands.install(in: registry)
        BrowserTabErgonomics.install(in: registry)
        BrowserArchiveCommands.install(in: registry)
        BrowserLibraryCommands.install(in: registry)
        BrowserBoostCommands.install(in: registry)
        BrowserFavoritesCommands.install(in: registry)
        BrowserSpaceCommands.install(in: registry)
        SidebarListCommands.install(in: registry)
        BrowserSplitCommands.install(in: registry)
        BrowserPageContextCommands.install(in: registry)
        func window(_ id: BrowserCommandID, _ action: @escaping (BrowserWindowController<Engine>) -> Void) {
            try! registry.register(id) { controller, _ in action(controller) }
        }
        try! registry.register(.capture, validate: { $0.engine.capabilities.contains(.snapshots) && $0.pageCommandSurface() != nil }) { controller, _ in
            controller.capture.begin()
        }
        try! registry.register(.captureFullPage, validate: { $0.engine.capabilities.contains(.fullPageSnapshots) && $0.pageCommandSurface() != nil }) { controller, _ in
            controller.capture.begin(fullPage: true)
        }
        try! registry.register(.savePageAs, validate: { $0.engine.capabilities.contains(.pageSaving) && $0.pageCommandSurface()?.navigationState.url != nil }) { controller, _ in
            controller.pageSaver.begin()
        }
        window(.newTab) { $0.openTab() }
        window(.openCommandBar) { $0.focusAddress() }
        BrowserPaletteCommands.install(in: registry)
        // SB-LIST: a sidebar multi-selection closes together, else the visible tab.
        window(.archiveTab) { $0.archiveSelectedTabs() }
        window(.duplicate) { $0.hideLibrary(); $0.duplicateSidebarTab() }
        window(.goBack) { $0.navigateBack() }
        window(.goForward) { $0.navigateForward() }
        window(.refreshThePage) { $0.reload() }
        try! registry.register(.forceRefreshThePage, validate: {
            $0.engine.capabilities.contains(.cacheBypassingReload) && $0.pageCommandSurface() != nil
        }) { controller, _ in
            controller.performDocumentCommand { try $0.reloadIgnoringCache() }
        }
        try! registry.register(.javascriptConsole, validate: { $0.canPerformPageCommand(.showDevTools) }) { controller, _ in
            controller.performDocumentCommand { try $0.showDeveloperPanel(.console) }
        }
        try! registry.register(.pasteAsNewTab, validate: { $0.session.paletteContext != nil }) { controller, _ in
            guard let text = pasteboardString(),
                  let destination = try? controller.addressResolver.resolve(text),
                  let context = controller.session.paletteContext else { return }
            controller.hideLibrary()
            controller.session.openTab(url: destination.url, from: context)
        }
        window(.stopLoading) { $0.session.performOnSelectedSurface { $0.stopLoading() } }
        window(.newSpace) { $0.presentNewSpace() }
        window(.renameSpace) { controller in
            if let id = controller.session.snapshot?.activeSpaceID { controller.presentRenameSpace(id) }
        }
        try! registry.register(.editTheme, validate: { $0.canEditActiveSpaceTheme }) { controller, _ in
            controller.presentActiveSpaceThemeEditor()
        }
        window(.previousSpace) { $0.activateAdjacentSpace(offset: -1) }
        window(.nextSpace) { $0.activateAdjacentSpace(offset: 1) }
        window(.find) { $0.findInLibraryOrPage() }
        window(.findNext) { $0.findNext() }
        window(.findPrevious) { $0.findPrevious() }
        window(.zoomIn) { $0.changePageZoom(.increase) }
        window(.zoomOut) { $0.changePageZoom(.decrease) }
        window(.zoomToActualSize) { $0.changePageZoom(.reset) }
        window(.copyURL) { $0.sharing.copyLink() }
        window(.copyURLAsMarkdown) { $0.sharing.copyMarkdownLink() }
        window(.share) { $0.sharing.sharePage() }
        window(.closeWindow) { controller in
            // Closing revokes session authority synchronously, even while its FIFO is stalled.
            controller.window?.performClose(nil)
        }
        window(.enterExitFullScreen) { controller in
            controller.session.performWindowAction { [weak controller] in controller?.window?.toggleFullScreen(nil) }
        }
        window(.minimizeWindow) { controller in
            controller.session.performWindowAction { [weak controller] in controller?.window?.performMiniaturize(nil) }
        }
        window(.zoom) { controller in
            controller.session.performWindowAction { [weak controller] in controller?.window?.performZoom(nil) }
        }
        window(.bringAllToFront) { controller in controller.session.performWindowAction { NSApp.arrangeInFront(nil) } }
        try! registry.register(.networkInspector, validate: { $0.canPerformPageCommand(.showDevTools) }) { controller, _ in
            controller.performDocumentCommand { try $0.showDeveloperPanel(.network) }
        }
        try! registry.register(.exit, validate: { $0.canExitCurrentContext }) { controller, _ in
            controller.exitCurrentContext()
        }
        for id in BrowserStandardActions.commandIDs {
            let selector = BrowserStandardActions.validationSelector(for: id)!
            let tag = BrowserStandardActions.tag(for: id)
            var pendingPermission: ((BrowserWindowController<Engine>) -> Bool)?
            if id == .undo || id == .redo {
                pendingPermission = { controller in
                    guard !(controller.window?.firstResponder is NSText) else { return false }
                    guard let responder = controller.commandResponder(for: selector, keyWindow: commandKeyWindow(), tag: tag) else { return false }
                    // Only these responders submit their accepted intents to the session FIFO.
                    // Field editors keep native validation and never inherit this permission.
                    return isSerializedSidebarResponder(responder, in: controller)
                }
            }
            try! registry.register(id, allowsPendingResponder: pendingPermission,
                                   validate: { $0.commandResponder(for: selector, keyWindow: commandKeyWindow(), tag: tag) != nil }) { controller, _ in
                guard let responder = controller.commandResponder(for: selector, keyWindow: commandKeyWindow(), tag: tag) else { return }
                if (id == .undo || id == .redo), controller.session.hasPendingCommands {
                    guard !(controller.window?.firstResponder is NSText), isSerializedSidebarResponder(responder, in: controller) else { return }
                }
                guard let sender = BrowserStandardActions.sender(for: id) else { return }
                if let manager = BrowserStandardActions.target(for: id) as? NSFontManager {
                    manager.addFontTrait(sender)
                } else {
                    responder.tryToPerform(sender.action!, with: sender)
                }
            }
        }
    }

    private static func isSerializedSidebarResponder<Engine: BrowserEngine>(
        _ responder: NSResponder, in controller: BrowserWindowController<Engine>
    ) -> Bool {
        responder === controller.sidebar.undoRouter || responder === controller.sidebar.page.list
    }
}
