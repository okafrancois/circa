import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Peek's command bindings, installed once after `BrowserWindowCommands`.
/// While a Peek is presented the window reports the `.peek` scope (see
/// `applyPeekCommandState(to:)`): Esc (`dismissPeek`) closes it, unless a native text field is being
/// edited, and ⌘W closes it instead of the tab underneath ().
/// R3: an open Library takes precedence for ⌘W and leaves the Peek and tab intact.
/// Page commands follow `pageCommandSurface()`: while the Peek has focus, back, forward, reload,
/// stop and copy URL act on the Peek document (PM decision; prototype `app/main.cjs:344-345`);
/// find and zoom do so inside their own extensions.
@MainActor
enum BrowserPeekCommands {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        func peekOrWindow(_ id: BrowserCommandID,
                          peek: @escaping (BrowserWindowController<Engine>, Engine.Surface) -> Void,
                          window: @escaping (BrowserWindowController<Engine>) -> Void) {
            try! registry.register(id, replace: true) { controller, _ in
                if controller.isPeekPageFocused, let surface = controller.presentedPeekSurface {
                    peek(controller, surface)
                } else {
                    window(controller)
                }
            }
        }
        // Native field editors (address, Find, rename, palette, dialogs) own Escape first.
        try! registry.register(.dismissPeek, validate: { $0.isPeekPresented && !$0.isTextFieldEditing }) { controller, _ in
            controller.dismissPeek()
        }
        try! registry.register(.openQuickWindowOrPeekIn, validate: { $0.isPeekPresented }) { controller, _ in
            controller.promotePeekToTab()
        }
        try! registry.register(.archiveTab, replace: true) { controller, _ in
            if controller.library.isPresented { controller.hideLibrary() }
            else if controller.isPeekPresented { controller.dismissPeek() }
            else { controller.archiveSelectedTabs() }
        }
        peekOrWindow(.goBack, peek: { _, surface in surface.goBack() }, window: { $0.navigateBack() })
        peekOrWindow(.goForward, peek: { _, surface in surface.goForward() }, window: { $0.navigateForward() })
        peekOrWindow(.refreshThePage, peek: { _, surface in surface.reload() }, window: { $0.reload() })
        peekOrWindow(.stopLoading, peek: { _, surface in surface.stopLoading() },
                     window: { $0.session.performOnSelectedSurface { $0.stopLoading() } })
        peekOrWindow(.copyURL, peek: { controller, surface in
            if let url = surface.navigationState.url { controller.sharing.copy(url, in: controller.contentCard) }
        }, window: { $0.sharing.copyLink() })
        peekOrWindow(.share, peek: { controller, surface in
            if let url = surface.navigationState.url { controller.sharing.share(url, title: surface.navigationState.title) }
        }, window: { $0.sharing.sharePage() })
        try! registry.register(.restoreLastClosedTab, replace: true) { controller, _ in
            controller.session.restoreMostRecentArchivedTab { [weak controller] archivedAt in
                guard let controller, controller.canReopenPeek, let closedAt = controller.peek.lastDismissed?.closedAt,
                      archivedAt.map({ closedAt > $0 }) ?? true else { return false }
                controller.reopenClosedPeek()
                return true
            }
        }
    }

}
