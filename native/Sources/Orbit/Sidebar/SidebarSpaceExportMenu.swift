import AppKit
import BrowserCore
import BrowserEngine

/// Captures the catalog and issuing window; deferred menu delivery never substitutes a target.
@MainActor
final class SidebarSpaceExportMenu<Engine: BrowserEngine>: NSObject, NSMenuItemValidation {
    private var item: NSMenuItem?

    static func make(owner: BrowserWindowController<Engine>, source: SpaceID) -> NSMenuItem? {
        guard let authority = Self(owner: owner, source: source), let item = authority.item else { return nil }
        authority.item = nil
        return item
    }
    private weak var owner: BrowserWindowController<Engine>?
    private let source: BrowserSpace
    private let context: BrowserCommandContext
    private let revision: UInt64
    private let destinations: [BrowserSpace]

    init?(owner: BrowserWindowController<Engine>, source id: SpaceID) {
        guard let context = owner.commandState.context, let catalog = owner.session.catalog,
              let source = catalog.spaces.first(where: { $0.id == id && $0.profileID == owner.session.organization?.profileID }),
              let organization = owner.session.organization else { return nil }
        self.owner = owner
        self.source = source
        self.context = context
        revision = organization.organizationRevision
        destinations = catalog.spaces.filter { $0.id != id && $0.profileID == source.profileID }
        guard !destinations.isEmpty else { return nil }
        let item = NSMenuItem(title: uiFormat("Export “%@” into Folder", source.name), action: nil, keyEquivalent: "")
        self.item = item
        super.init()
        let menu = NSMenu(title: item.title)
        for (index, space) in destinations.enumerated() {
            let row = NSMenuItem(title: space.name, action: #selector(export(_:)), keyEquivalent: "")
            row.target = self
            row.tag = index
            menu.addItem(row)
        }
        item.submenu = menu
        item.isEnabled = !destinations.isEmpty
        // NSMenuItem targets are weak; the submenu retains this captured authority.
        menu.items.forEach { $0.representedObject = self }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let owner, owner.acceptsCommands, !owner.session.hasPendingCommands,
              owner.commandState.context == context, owner.session.organization?.organizationRevision == revision,
              destinations.indices.contains(menuItem.tag), let catalog = owner.session.catalog else { return false }
        return catalog.spaces.contains(source) && catalog.spaces.contains(destinations[menuItem.tag])
    }

    @objc func export(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let owner else { return }
        owner.performAcceptedCommand { owner.session.exportSpace(source.id, to: destinations[sender.tag].id) }
    }
}
