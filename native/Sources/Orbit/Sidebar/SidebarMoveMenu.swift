import AppKit
import BrowserCore
import BrowserEngine

/// A Move to submenu retains its destinations and the exact object/window snapshot it opened on.
/// AppKit may deliver an action after closing the menu; no current selection is substituted.
@MainActor
final class SidebarMoveMenu<Engine: BrowserEngine>: NSObject, NSMenuItemValidation {
    let item = NSMenuItem(title: uiText("Move to"), action: nil, keyEquivalent: "")
    private weak var owner: BrowserWindowController<Engine>?
    private let nodes: [BrowserOrganizationNode]
    private let organizationRevision: UInt64
    private let context: BrowserCommandContext
    private var destinations: [BrowserOrganizationDestination] = []

    init?(owner: BrowserWindowController<Engine>, nodes: [BrowserOrganizationNode]) {
        guard let context = owner.commandState.context, !nodes.isEmpty,
              let organization = owner.session.organization, let catalog = owner.session.catalog else { return nil }
        self.owner = owner
        self.nodes = nodes
        self.context = context
        self.organizationRevision = organization.organizationRevision
        super.init()
        let menu = NSMenu(title: item.title)
        func add(_ title: String, _ container: BrowserOrganizationContainer, to menu: NSMenu) {
            let destination = BrowserOrganizationDestination(container, position: .end)
            guard organization.validateMove(nodes, to: destination, catalog: catalog) == nil else { return }
            let row = NSMenuItem(title: title, action: #selector(move(_:)), keyEquivalent: "")
            row.target = self
            row.tag = destinations.count
            destinations.append(destination)
            menu.addItem(row)
        }
        add(uiText("Favorites"), .favorites(organization.profileID), to: menu)
        for space in catalog.spaces where space.profileID == organization.profileID {
            let submenu = NSMenu(title: space.name)
            add(uiText("Pinned"), .pinned(space.id), to: submenu)
            add(uiText("Today"), .today(space.id), to: submenu)
            if space.id == organization.spaceID {
                func folders(_ items: [BrowserOrganizationItem], in menu: NSMenu) {
                    for case .folder(let folder) in items {
                        add(folder.title, .folder(folder.id), to: menu)
                        folders(folder.children, in: menu)
                    }
                }
                folders(organization.pinned, in: submenu)
            }
            guard !submenu.items.isEmpty else { continue }
            let row = NSMenuItem(title: space.name, action: nil, keyEquivalent: "")
            row.submenu = submenu
            menu.addItem(row)
        }
        item.submenu = menu
        guard !destinations.isEmpty else { return nil }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let owner, owner.acceptsCommands, owner.commandState.context == context,
              !owner.session.hasPendingCommands, destinations.indices.contains(menuItem.tag),
              let organization = owner.session.organization, organization.organizationRevision == organizationRevision,
              let catalog = owner.session.catalog else { return false }
        return organization.validateMove(nodes, to: destinations[menuItem.tag], catalog: catalog) == nil
    }

    @objc private func move(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let owner else { return }
        let destination = destinations[sender.tag]
        owner.performAcceptedCommand { owner.session.moveItems(nodes, to: destination) }
    }
}

@MainActor
final class SidebarContextMenuOwner {
    let commands: AnyObject
    let move: AnyObject?
    init(commands: AnyObject, move: AnyObject?) { self.commands = commands; self.move = move }
}
