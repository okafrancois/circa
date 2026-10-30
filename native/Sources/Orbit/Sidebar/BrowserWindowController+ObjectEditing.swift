import AppKit
import BrowserCore

extension BrowserWindowController {
    var sidebarSingleTab: BrowserOrganizationTabItem? {
        let targets = sidebar.commandTargets()
        guard targets.count == 1, let id = targets[0].tabID else { return nil }
        return session.organization?.tab(id)
    }

    func presentTabIconPicker() {
        guard acceptsCommands, let tab = sidebarSingleTab, let snapshot = session.organization,
              let y = sidebar.page.list.displayedCenterY(of: .node(.tab(tab.id))) else { return }
        let picker = SpaceIconPicker(currentChoice: tab.customIcon ?? .none, accent: sidebar.footer.accent, purpose: .tab)
        tabIconPicker?.cancel()
        tabIconPicker = picker
        picker.onChooseIcon = { [weak self] value in
            guard let self, acceptsCommands, session.organization?.spaceID == snapshot.spaceID,
                  session.activeProfileID == snapshot.profileID, session.organization?.tab(tab.id) != nil else { return }
            session.changeTabIcon(tab.id, to: value == .none ? nil : value)
        }
        picker.onClose = { [weak self, weak picker] in
            if self?.tabIconPicker === picker { self?.tabIconPicker = nil }
        }
        let list = sidebar.page.list
        let anchor = NSRect(x: 8, y: y - 12, width: 20, height: 24)
        if !picker.show(relativeTo: list, anchor: anchor) { tabIconPicker = nil }
    }

    func presentPinnedURLEditor() {
        guard acceptsCommands, let tab = sidebarSingleTab, let url = tab.pinnedURL,
              let snapshot = session.organization, let host = window?.contentView else { return }
        pinnedURLEditor?.complete(save: false)
        let editor = PinnedURLEditor(url: url) { [weak self] value in
            guard let self, acceptsCommands, session.organization?.spaceID == snapshot.spaceID,
                  session.activeProfileID == snapshot.profileID,
                  session.organization?.tab(tab.id)?.pinnedURL != nil else { return }
            session.editPinnedURL(tab.id, to: value)
            resetSidebarTab(tab.id)
        }
        pinnedURLEditor = editor
        editor.onClose = { [weak self, weak editor] in
            if self?.pinnedURLEditor === editor { self?.pinnedURLEditor = nil }
        }
        editor.show(in: host)
    }

}
