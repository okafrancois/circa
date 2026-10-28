import AppKit
import BrowserCore

/// Local inventory reconstruction. It reads catalog metadata, never materializes a site's surface.
@MainActor
final class BrowserLibrarySpacesView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Item: Equatable {
        let space: BrowserSpace
        let profileName: String
        let iconSelection: BrowserSpaceIcon
        var icon: String? { if case .grapheme(let value) = iconSelection { value } else { nil } }
    }
    let searchField = BrowserLibrarySearchField()
    let table = ArchiveTableView()
    private let status = NSTextField(labelWithString: "")
    private let open = NSButton(title: uiText("Open Space"), target: nil, action: nil)
    private var items: [Item] = []
    private(set) var rows: [Item] = []
    private var catalog: BrowserCatalogSnapshot?
    private var activeSpaceID: SpaceID?
    private var presentation: UUID?
    private var sourceProfile: ProfileID?
    var onOpen: ((SpaceID, BrowserCatalogSnapshot, UUID) -> Void)?
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.placeholderString = uiText("Search Spaces…")
        searchField.maximumRecents = 0
        searchField.recentsAutosaveName = nil
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("library-spaces-search")
        table.addTableColumn(NSTableColumn(identifier: .init("spaces")))
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 56
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.setAccessibilityIdentifier("library-spaces-list")
        table.setAccessibilityLabel(uiText("Spaces"))
        table.target = self
        table.action = #selector(openSelected)
        table.onReturn = { [weak self] in self?.openSelected() }
        table.onEscape = { [weak self] in self?.cancelOperation(nil) }
        open.target = self
        open.action = #selector(openSelected)
        open.setAccessibilityIdentifier("library-spaces-open")
        status.font = OrbitTokens.Typography.emptyStateDetail
        status.textColor = OrbitTokens.Color.Text.secondary
        let scroll = NSScrollView()
        scroll.documentView = table
        BrowserLibraryStyle.configure(scroll)
        let stack = NSStackView(views: [searchField, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
        open.isEnabled = false
    }
    required init?(coder: NSCoder) { nil }

    func render(catalog: BrowserCatalogSnapshot, activeSpaceID: SpaceID?, sourceProfile: ProfileID,
                icons: [SpaceID: BrowserSpaceIcon], presentation: UUID) {
        if self.presentation != presentation || self.sourceProfile != sourceProfile {
            searchField.stringValue = ""
            table.deselectAll(nil)
        }
        self.presentation = presentation
        self.sourceProfile = sourceProfile
        self.catalog = catalog
        self.activeSpaceID = activeSpaceID
        let profiles = Dictionary(uniqueKeysWithValues: catalog.profiles.map { ($0.id, $0.name) })
        items = catalog.spaces.compactMap { space in
            guard let profile = profiles[space.profileID] else { return nil }
            return Item(space: space, profileName: profile, iconSelection: icons[space.id] ?? .none)
        }
        filter()
    }

    func clear() {
        catalog = nil; presentation = nil; sourceProfile = nil; activeSpaceID = nil
        items = []; rows = []; searchField.stringValue = ""
        table.reloadData(); open.isEnabled = false
    }

    func controlTextDidChange(_ notification: Notification) { filter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelOperation(nil); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !rows.isEmpty else { return true }
            let next = selector == #selector(NSResponder.moveDown(_:))
                ? min(rows.count - 1, table.selectedRow + 1) : max(0, table.selectedRow - 1)
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
            return true
        }
        return false
    }
    override func cancelOperation(_ sender: Any?) {
        if !searchField.stringValue.isEmpty { searchField.stringValue = ""; filter() }
        else { onBack?() }
    }

    private func filter() {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].space.id : nil
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = items.filter { query.isEmpty || ($0.space.name + " " + $0.profileName)
            .range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        table.reloadData()
        table.deselectAll(nil)
        if let selected, let index = rows.firstIndex(where: { $0.space.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        status.stringValue = rows.isEmpty ? uiText("No Spaces Found") : uiText("Select a Space to open it.")
        open.isEnabled = rows.indices.contains(table.selectedRow)
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        BrowserLibraryRowView()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { open.isEnabled = rows.indices.contains(table.selectedRow) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let icon = SpaceIconImages.view(item.iconSelection)
        let title = NSTextField(labelWithString: item.space.name)
        title.font = OrbitTokens.Typography.sidebarFolderTitle
        title.lineBreakMode = .byTruncatingTail
        let profile = NSTextField(labelWithString: item.profileName)
        profile.font = OrbitTokens.Typography.menuShortcut
        profile.textColor = OrbitTokens.Color.Text.secondary
        let text = NSStackView(views: [title, profile]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 3
        let current = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: uiText("Current Space")) ?? NSImage())
        current.isHidden = item.space.id != activeSpaceID
        let cell = NSStackView(views: [icon, text, NSView(), current]); cell.spacing = 12
        cell.setAccessibilityLabel(item.space.name + ", " + item.profileName)
        return cell
    }
    @objc func openSelected() {
        guard rows.indices.contains(table.selectedRow), let catalog, let presentation else { return }
        onOpen?(rows[table.selectedRow].space.id, catalog, presentation)
    }
}
