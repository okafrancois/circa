import AppKit
import BrowserCore

extension BrowserWindowController {
    /// Captures the exact tab and window context, independent of sidebar selection and menu lifetime.
    func tabContextAction(_ title: String, tab: BrowserOrganizationTabItem, enabled: Bool = true,
                          action: @escaping (BrowserWindowController) -> Void) -> NSMenuItem {
        let context = commandState.context
        let item = BrowserSplitMenuItem(title: title) { [weak self] in
            guard enabled, let self, BrowserCommandKeyboard.permitsCurrentMenuEvent(), acceptsCommands,
                  commandState.context == context, session.organization?.tab(tab.id) == tab else { return }
            submitInput { controller in
                guard controller.session.organization?.tab(tab.id) == tab else { return }
                action(controller)
            }
        }
        item.isEnabled = enabled
        return item
    }

    func pinnedPageMenu(for tab: BrowserOrganizationTabItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(tabContextAction(uiText("Replace Pinned URL with Current"), tab: tab,
            enabled: tab.pinnedURL != nil && tab.url != tab.pinnedURL) { controller in
                controller.session.editPinnedURL(tab.id, to: tab.url)
            })
        menu.addItem(tabContextAction(uiText("Reset Tab to Original URL"), tab: tab,
            enabled: tab.isAwayFromPinnedURL) { controller in controller.resetSidebarTab(tab.id) })
        menu.addItem(tabContextAction(uiText("Edit Pinned URL…"), tab: tab,
            enabled: tab.pinnedURL != nil) { controller in controller.presentPinnedURLEditor(tab) })
        return menu
    }

    func tabShareMenu(for tab: BrowserOrganizationTabItem) -> NSMenuItem {
        sharing.menuItem(for: tab.url)
    }

    func tabMuteMenuItem(for tab: BrowserOrganizationTabItem) -> NSMenuItem {
        let surface = liveSidebarSurface(of: tab.id)
        let media = surface.flatMap { siteControls.mediaStates[ObjectIdentifier($0)] }
        return tabContextAction(uiText(media?.isAudioMuted == true ? "Unmute" : "Mute"), tab: tab,
            enabled: engine.capabilities.contains(.audioMuting) && (media?.isAudible == true || media?.isAudioMuted == true)) { controller in
                guard let surface = controller.liveSidebarSurface(of: tab.id) else { return }
                controller.toggleSplitPaneMute(surface)
            }
    }
}

