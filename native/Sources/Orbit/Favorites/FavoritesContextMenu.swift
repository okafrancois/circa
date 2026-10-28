import AppKit

/// Object-specific presentation over the shared command registry. Closures capture the exact
/// object before dispatch; the registry still validates and routes the window/document target.
/// Weak feature captures avoid retaining registry → router → window → feature → registry.
@MainActor
final class FavoritesContextMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    let menu = NSMenu()
    var isEnabled: ((BrowserCommandID) -> Bool)?
    var onInvoke: ((BrowserCommandID) -> Void)?
    var onClose: (() -> Void)?
    var retainedOwners: [AnyObject] = []

    init(definitions: [BrowserCommandDefinition]) {
        super.init()
        menu.delegate = self
        for definition in definitions {
            let item = NSMenuItem(title: definition.localizedTitle, action: #selector(invoke(_:)), keyEquivalent: "")
            item.identifier = .init(definition.id.rawValue)
            item.target = self
            if definition.id == .removeFavorite, !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(item)
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard BrowserCommandKeyboard.permitsCurrentMenuEvent(), let id = command(menuItem) else { return false }
        return isEnabled?(id) == true
    }
    func menuDidClose(_ menu: NSMenu) { onClose?() }
    private func command(_ item: NSMenuItem) -> BrowserCommandID? { item.identifier.flatMap { BrowserCommandID(rawValue: $0.rawValue) } }
    @objc private func invoke(_ sender: NSMenuItem) {
        guard BrowserCommandKeyboard.permitsCurrentMenuEvent(), let id = command(sender) else { return }
        onInvoke?(id)
    }
}
