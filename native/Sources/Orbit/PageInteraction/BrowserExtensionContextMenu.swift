import AppKit
import BrowserEngine

/// Retained for the duration of AppKit's synchronous menu tracking.
@MainActor
final class BrowserExtensionContextMenu: NSObject, NSMenuItemValidation {
    private let perform: (Int32) -> Void
    init(perform: @escaping (Int32) -> Void) { self.perform = perform }

    func append(_ items: [BrowserExtensionMenuItem], to menu: NSMenu) {
        guard !items.isEmpty else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for item in items {
            if item.isSeparator { menu.addItem(.separator()); continue }
            let entry = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = Int(item.commandID)
            entry.representedObject = item.isEnabled
            entry.isEnabled = item.isEnabled
            entry.state = item.isChecked ? .on : .off
            if !item.children.isEmpty {
                let submenu = NSMenu(title: item.title)
                submenu.autoenablesItems = false
                append(item.children, to: submenu)
                entry.submenu = submenu
            }
            menu.addItem(entry)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { menuItem.representedObject as? Bool ?? false }

    @objc private func choose(_ sender: NSMenuItem) { perform(Int32(sender.tag)) }
}
