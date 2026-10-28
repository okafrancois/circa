import AppKit
import BrowserCore

extension BrowserWindowController {
    func makeSplitPaneMenu(_ tabID: TabID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let split = session.activeSplit, let index = split.group.tabIDs.firstIndex(of: tabID) else { return menu }
        let group = split.group
        let context = session.splitCommandContext
        func item(_ title: String, symbol: String, enabled: Bool = true, action: @escaping () -> Void) {
            let entry = BrowserSplitMenuItem(title: title) { [weak self] in
                guard let self, acceptsCommands, session.splitCommandContext == context,
                      session.activeSplit?.group == group else { return }
                action()
            }
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if #available(macOS 27.0, *) { entry.preferredImageVisibility = .visible }
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        item(uiText("Move Left"), symbol: "rectangle.lefthalf.inset.filled.arrow.left", enabled: index > 0) { [weak self] in
            self?.session.swapSplitPanes(group.id, first: index, second: index - 1)
        }
        item(uiText("Move Right"), symbol: "rectangle.righthalf.inset.filled.arrow.right", enabled: index + 1 < group.tabIDs.count) { [weak self] in
            self?.session.swapSplitPanes(group.id, first: index, second: index + 1)
        }
        menu.addItem(.separator())
        item(uiText("Add Right Split"), symbol: "rectangle.righthalf.inset.filled", enabled: canAddSplitPane) { [weak self] in
            self?.addSplitFromSelection(at: index + 1)
        }
        item(uiText("Add Left Split"), symbol: "rectangle.lefthalf.inset.filled", enabled: canAddSplitPane) { [weak self] in
            self?.addSplitFromSelection(at: index)
        }
        menu.addItem(.separator())
        item(uiText("Separate Tab from Split"), symbol: "rectangle.portrait.and.arrow.right") { [weak self] in
            self?.session.separateSplitPane(tabID)
        }
        item(group.orientation == .horizontal ? uiText("Convert to Vertical Split View") : uiText("Convert to Horizontal Split View"),
             symbol: group.orientation == .horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1") { [weak self] in
            self?.session.orientSplit(group.id, to: group.orientation == .horizontal ? .vertical : .horizontal)
        }
        menu.addItem(.separator())
        item(uiText("Share Split View…"), symbol: "square.and.arrow.up") { [weak self] in
            guard let self, let pane = self.split.view.panes[tabID] else { return }
            let picker = NSSharingServicePicker(items: split.tabs.map(\.url))
            self.split.sharingPicker = picker
            picker.show(relativeTo: pane.splitToggle.bounds, of: pane.splitToggle, preferredEdge: .minY)
        }
        return menu
    }
}

@MainActor
private final class BrowserSplitMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func invoke() { handler() }
}
