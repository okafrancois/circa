import AppKit

/// Builds the declared menu tree and routes commands through the shared registry.
@MainActor
final class BrowserCommandMenus<Window: AnyObject>: NSObject, NSMenuItemValidation {
    static func applicationDisplayName(bundleIdentifier: String?) -> String {
        bundleIdentifier == "io.github.okatech.orbit.test.orbit.live" ? uiText("Orbit Live") : uiText("Orbit")
    }

    static var applicationDisplayName: String { applicationDisplayName(bundleIdentifier: Bundle.main.bundleIdentifier) }

    static var topLevelTitles: [String] {
        OrbitMenuTree.bar.compactMap { node in
            guard case .submenu(let spec) = node else { return nil }
            return spec.systemName == "_NSAppleMenu" ? applicationDisplayName : uiText(spec.title)
        }
    }

    static var suppressedKeyEquivalents: Set<BrowserCommandID> { [.newFolder] }

    let registry: BrowserCommandRegistry<Window>
    private let target: BrowserCommandTarget?
    private let keyWindowProvider: () -> NSWindow?

    init(registry: BrowserCommandRegistry<Window>, target: BrowserCommandTarget? = nil,
         keyWindow: @escaping () -> NSWindow? = { NSApp?.keyWindow }) {
        self.registry = registry
        self.target = target
        self.keyWindowProvider = keyWindow
    }

    func makeMenuBar() -> NSMenu {
        let bar = BrowserKeyEquivalentMenu(title: uiText("Main Menu"))
        bar.routeKeyEquivalent = { [weak self] event in self?.routeKeyEquivalent(event) }
        bar.onKeyEquivalentResult = { [weak registry] event, result in
            registry?.keyTrace.record("menu", event, "result=\(result)")
        }
        for case .submenu(let spec) in OrbitMenuTree.bar {
            let item = makeSubmenuItem(spec, title: spec.systemName == "_NSAppleMenu" ? Self.applicationDisplayName : uiText(spec.title))
            if item.submenu?.items.contains(where: { !$0.isSeparatorItem && !$0.isHidden }) == true { bar.addItem(item) }
        }
        return bar
    }

    /// Context menus use the same item configuration and a target captured before opening.
    /// The owner must retain this controller for as long as AppKit retains the displayed menu.
    func makeContextMenu(commands: [BrowserCommandID]) -> NSMenu {
        let menu = NSMenu()
        for id in commands {
            guard isAvailableInMenus(id), let definition = registry.definition(id) else { continue }
            let shortcut = definition.shortcuts.first
            let item = NSMenuItem(title: definition.localizedTitle, action: nil, keyEquivalent: shortcut?.key ?? "")
            item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
            configure(item, command: id)
            menu.addItem(item)
        }
        return menu
    }

    private static var fileAppendix: [BrowserCommandID] {
        [.importFromArc]
    }

    private func makeSubmenuItem(_ spec: OrbitSubmenuSpec, title: String) -> NSMenuItem {
        let menu = NSMenu(title: spec.systemName == "_NSAppleMenu" ? title : uiText(spec.menuTitle))
        var emitted: Set<String> = []
        for child in spec.children {
            if let item = makeItem(child, emitted: &emitted) { menu.addItem(item) }
        }
        // File appends the single Orbit-specific import entry required by the product brief.
        let present = Set(menu.items.compactMap { $0.identifier?.rawValue })
        let featureIDs = OrbitCommandCatalog.featureDefinitions
            .filter { spec.menuTitle == "File" && Self.fileAppendix.contains($0.id) && !present.contains($0.id.rawValue) }
            .map(\.id)
        let features = makeContextMenu(commands: featureIDs).items
        if !features.isEmpty {
            let separator = NSMenuItem.separator()
            applyOrbitKeyEquivalentAdaptation(separator)
            menu.addItem(separator)
            for feature in features {
                feature.menu?.removeItem(feature)
                menu.addItem(feature)
            }
        }
        normalizeSeparators(in: menu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        item.title = title // Assigned after the submenu: Spelling and Appearance differ.
        item.isHidden = spec.isHidden
        if spec.command == .services { item.identifier = NSUserInterfaceItemIdentifier(BrowserCommandID.services.rawValue) }
        applyOrbitKeyEquivalentAdaptation(item)
        return item
    }

    private func makeItem(_ node: OrbitMenuNode, emitted: inout Set<String>) -> NSMenuItem? {
        switch node {
        case .separator:
            let item = NSMenuItem.separator()
            applyOrbitKeyEquivalentAdaptation(item)
            return item
        case .header(let command, let title):
            let item = NSMenuItem(title: localizedTitle(command, fallback: title), action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            item.isEnabled = false
            applyOrbitKeyEquivalentAdaptation(item)
            return item
        case .submenu(let spec):
            let item = makeSubmenuItem(spec, title: spec.command.map { localizedTitle($0, fallback: spec.title) } ?? uiText(spec.title))
            guard spec.command == .services || item.submenu?.items.contains(where: { !$0.isHidden && ($0.action != nil || $0.submenu != nil) }) == true else { return nil }
            return item
        case .item(let spec):
            guard isAvailableInMenus(spec.command) else { return nil }
            let suppressed = Self.suppressedKeyEquivalents.contains(spec.command)
                && registry.shortcutPreferences.document.overrides[spec.command.rawValue] == nil
            let override = registry.shortcutPreferences.document.overrides[spec.command.rawValue]
            let custom = override?.first?.shortcut
            let key = suppressed ? "" : (override != nil ? custom?.key ?? "" : spec.key)
            guard key.isEmpty || emitted.insert("\(spec.command.rawValue)|\(key)|\(spec.modifierMask)").inserted else { return nil }
            let item = NSMenuItem(title: displayTitle(spec), action: nil, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : (override != nil ? custom?.modifiers ?? [] : NSEvent.ModifierFlags(rawValue: spec.modifierMask))
            item.isHidden = spec.isHidden && spec.command != .duplicate
            item.isAlternate = spec.isAlternate
            item.allowsKeyEquivalentWhenHidden = spec.allowsKeyEquivalentWhenHidden
            item.state = spec.isOn ? .on : .off
            configure(item, command: spec.command)
            return item
        }
    }

    private func configure(_ item: NSMenuItem, command id: BrowserCommandID) {
        item.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        applyOrbitKeyEquivalentAdaptation(item)
        if let selector = BrowserStandardActions.selector(for: id) {
            item.action = selector
            item.target = BrowserStandardActions.target(for: id)
            item.tag = BrowserStandardActions.tag(for: id)
            return
        }
        item.action = #selector(invoke(_:))
        item.target = self
        item.isEnabled = registry.isEnabled(id, target: target)
        if id == .editTheme {
            item.toolTip = uiText("Requires an active Space in a browser window with theme editing available.")
            item.setAccessibilityHelp(item.toolTip)
        }
    }

    /// Native responder actions work in fields and sheets even without a browser handler.
    private func isAvailableInMenus(_ id: BrowserCommandID) -> Bool {
        !OrbitCommandCatalog.hiddenCommands.contains(id) && (registry.isImplemented(id) || BrowserStandardActions.selector(for: id) != nil)
    }

    /// Omitted commands must not leave empty groups or separators attached only to hidden aliases.
    private func normalizeSeparators(in menu: NSMenu) {
        var hasVisibleItem = false
        var pending: NSMenuItem?
        for item in menu.items {
            if item.isSeparatorItem {
                if let previous = pending { menu.removeItem(previous) }
                pending = item
                if !hasVisibleItem { menu.removeItem(item); pending = nil }
            } else if !item.isHidden {
                hasVisibleItem = true
                pending = nil
            }
        }
        if let pending { menu.removeItem(pending) }
    }

    /// Follow Orbit's actual serialized adaptation flags. Native AppKit matching remains
    /// authoritative for localized and mirrored key equivalents.
    private func applyOrbitKeyEquivalentAdaptation(_ item: NSMenuItem) {
        item.allowsAutomaticKeyEquivalentLocalization = OrbitMenuTree.allowsKeyEquivalentLocalization
        item.allowsAutomaticKeyEquivalentMirroring = OrbitMenuTree.allowsKeyEquivalentMirroring
    }

    private func displayTitle(_ spec: OrbitMenuItemSpec) -> String {
        let renamed: [BrowserCommandID: String] = [.aboutOrbit: uiFormat("About %@", Self.applicationDisplayName), .quitOrbit: uiFormat("Quit %@", Self.applicationDisplayName), .hideOrbit: uiFormat("Hide %@", Self.applicationDisplayName)]
        return renamed[spec.command] ?? localizedTitle(spec.command, fallback: spec.title)
    }

    private func localizedTitle(_ id: BrowserCommandID, fallback: String) -> String {
        uiText(fallback)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let value = menuItem.identifier?.rawValue, let id = BrowserCommandID(rawValue: value) else { return false }
        if target == nil, let selector = BrowserStandardActions.keyWindowSelector(for: id), let window = nonBrowserKeyWindow() {
            let probe = NSMenuItem(title: menuItem.title, action: selector, keyEquivalent: "")
            return window.responds(to: selector) && window.validateUserInterfaceItem(probe)
        }
        guard BrowserCommandKeyboard.permitsCurrentMenuEvent(), !nativeTextOwnsCurrentKey(menuItem) else { return false }
        return registry.isEnabled(id, target: target)
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        guard let value = sender.identifier?.rawValue, let id = BrowserCommandID(rawValue: value) else { return }
        if target == nil, let selector = BrowserStandardActions.keyWindowSelector(for: id), let window = nonBrowserKeyWindow() {
            NSApp.sendAction(selector, to: window, from: sender)
            return
        }
        guard BrowserCommandKeyboard.permitsCurrentMenuEvent() else { return }
        registry.dispatch(id, origin: target == nil ? .menu : .contextMenu, target: target)
    }

    /// Called by the menu only after the key window / focused page declined the key. Native
    /// text actions and system-inserted items keep AppKit's nil-target path. Supplemental
    /// commands need no fake visible menu item to receive this same post-page fallback.
    private func routeKeyEquivalent(_ event: NSEvent) -> Bool? {
        let input = keyWindowProvider()?.firstResponder as? NSTextInputClient
        guard let normalized = registry.eventInputs.normalized(event, isComposing: input?.hasMarkedText() == true) else { return nil }
        // A native field receives unmodified function/Escape keys through keyDown, after
        // the key-equivalent stage. Do not steal those keys for future browser commands.
        if normalized.shortcut.modifiers.intersection([.command, .control, .option]).isEmpty,
           BrowserCommandTextInput.isEditing(keyWindowProvider()?.firstResponder) { return false }
        let candidates = registry.matchingDefinitions(normalized)
        if candidates.contains(where: { BrowserStandardActions.selector(for: $0.id) != nil }) { return nil }
        if target == nil, nonBrowserKeyWindow() != nil,
           candidates.contains(where: { BrowserStandardActions.keyWindowSelector(for: $0.id) != nil }) { return nil }
        if event.modifierFlags.intersection([.command, .control, .option]) == [.command],
           ["\u{F702}", "\u{F703}"].contains(event.charactersIgnoringModifiers ?? ""),
           BrowserCommandTextInput.isEditing(keyWindowProvider()?.firstResponder) { return false }
        if let id = registry.resolveBinding(normalized),
           registry.shortcutPreferences.priority(for: id) == .both { return false }
        if let id = registry.resolveBinding(normalized), registry.prefersBrowser(id) {
            let accepted = registry.dispatch(id, origin: .keyboard, target: target)
            return accepted || registry.hasBrowserCommandTarget
        }
        if let id = registry.resolve(normalized) {
            return registry.dispatch(id, origin: .keyboard, target: target)
        }
        // AppKit can accept extra Shift for function-key equivalents. Reject only a
        // known unshifted browser binding, leaving unrelated system menu keys available.
        if registry.hasUnshiftedFunctionBinding(normalized) { return false }
        return candidates.isEmpty ? nil : false
    }

    /// The key window when it is not one of the router's browser windows (Settings, panels).
    private func nonBrowserKeyWindow() -> NSWindow? {
        guard let key = keyWindowProvider() else { return nil }
        let owned = registry.router.windows.values.contains { window in
            ((window as? NSWindowController)?.window ?? (window as? NSWindow)) === key
        }
        return owned ? nil : key
    }

    /// ⌘←/⌘→ also serialize Go Back/Forward (hidden aliases). In a native text view they
    /// move the insertion point; the disabled item lets the event reach the field editor.
    private func nativeTextOwnsCurrentKey(_ item: NSMenuItem) -> Bool {
        guard let event = NSApp?.currentEvent, event.type == .keyDown, event.charactersIgnoringModifiers == item.keyEquivalent,
              item.keyEquivalentModifierMask == [.command], ["\u{F702}", "\u{F703}"].contains(item.keyEquivalent) else { return false }
        return BrowserCommandTextInput.isEditing(keyWindowProvider()?.firstResponder)
    }
}
