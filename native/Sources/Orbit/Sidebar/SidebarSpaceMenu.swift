import AppKit
import BrowserCore

struct SidebarSpaceAction {
    enum Kind: String { case rename, icon, theme, moveLeft, moveRight, delete }
    let kind: Kind
    let title: String
    let symbol: String
    let enabled: Bool
    let beforeID: SpaceID?
    var startsGroup: Bool { kind == .moveLeft || kind == .delete }
    var destructive: Bool { kind == .delete }
}

/// Product choice: creation-menu typography and 40 pt rows over native popover material.
/// This composition uses a 24 pt native menu.
@MainActor
final class SidebarSpaceMenu: NSViewController {
    let actions: [SidebarSpaceAction]
    let popup = SidebarCreationPopup()
    var onClose: (() -> Void)?
    var onAction: ((SidebarSpaceAction) -> Void)?
    private let accent: OrbitTokens.ThemeAccent
    private var rows: [CreationMenuRow] = []
    private var selection = -1
    private var cancelled = false
    private weak var previousResponder: NSResponder?
    private weak var sourceWindow: NSWindow?
    static let width: CGFloat = 264

    init(actions: [SidebarSpaceAction], accent: OrbitTokens.ThemeAccent) {
        self.actions = actions
        self.accent = accent
        super.init(nibName: nil, bundle: nil)
        popup.usesGlass = true
        popup.contentViewController = self
        popup.onClose = { [weak self] in
            guard let self else { return }
            cancelled = true
            if let sourceWindow, sourceWindow.isKeyWindow, let previousResponder {
                sourceWindow.makeFirstResponder(previousResponder)
            }
            onClose?()
        }
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = CreationMenuContent()
        content.setAccessibilityRole(.menu)
        content.setAccessibilityLabel(uiText("Space Settings"))
        content.onKey = { [weak self] in self?.handle($0) ?? false }
        var y: CGFloat = 8
        for (index, action) in actions.enumerated() {
            if action.startsGroup {
                let separator = NSBox(frame: NSRect(x: 18, y: y + 5, width: Self.width - 36, height: 1))
                separator.boxType = .separator
                content.addSubview(separator)
                y += 12
            }
            let row = CreationMenuRow(title: action.title, symbol: action.symbol, enabled: action.enabled,
                                      identifier: "space-menu-" + action.kind.rawValue, accent: accent,
                                      destructive: action.destructive)
            row.frame = NSRect(x: 6, y: y, width: Self.width - 12, height: OrbitTokens.Metrics.Sidebar.plusMenuItemPitch)
            row.onPress = { [weak self] in self?.activate(index) }
            row.onHover = { [weak self] in self?.select(index) }
            rows.append(row)
            content.addSubview(row)
            y += row.frame.height
        }
        content.frame = NSRect(x: 0, y: 0, width: Self.width, height: y + 8)
        view = content
    }

    func show(relativeTo button: NSView) {
        previousResponder = button.window?.firstResponder
        sourceWindow = button.window
        popup.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        select(actions.firstIndex(where: \.enabled) ?? -1)
        popup.window?.makeFirstResponder(view)
    }
    func cancel() {
        cancelled = true
        popup.performClose(nil)
    }
    private func select(_ index: Int) {
        guard actions.indices.contains(index), actions[index].enabled else { return }
        selection = index
        for (i, row) in rows.enumerated() { row.setSelected(i == index) }
    }
    func activate(_ index: Int) {
        guard !cancelled, actions.indices.contains(index), actions[index].enabled else { return }
        let action = actions[index]
        cancelled = true
        popup.performClose(nil)
        onAction?(action)
    }
    @discardableResult
    func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        case #selector(NSResponder.insertNewline(_:)): activate(selection)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            let delta = selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) ? -1 : 1
            guard !actions.isEmpty else { return true }
            for step in 1...actions.count {
                let index = ((selection + delta * step) % actions.count + actions.count) % actions.count
                if actions[index].enabled { select(index); break }
            }
        default: return false
        }
        return true
    }
}
