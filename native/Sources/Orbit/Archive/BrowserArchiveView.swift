import AppKit
import BrowserCore

func archiveText(_ key: String, _ fallback: String) -> String {
    uiText(fallback)
}

/// Embeddable Library category; day headings are nonselectable table rows.
@MainActor
final class BrowserArchiveView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Row: Equatable { case day(Date), tab(BrowserArchivedTab) }
    let searchField = BrowserLibrarySearchField()
    let table = ArchiveTableView()
    let settings = NSPopUpButton()
    private var embedded = false
    private var standaloneControls: [NSView] = []
    func setLibraryEmbedded() {
        embedded = true
        standaloneControls.forEach { $0.isHidden = true }
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    private let profileLabel = NSTextField(labelWithString: "")
    private let empty = BrowserLibraryEmptyView()
    private var recordActions: NSView?
    private let restoreButton = NSButton(title: archiveText("restore", "Restore"), target: nil, action: nil)
    private let deleteButton = NSButton(title: archiveText("delete", "Delete"), target: nil, action: nil)
    private(set) var rows: [Row] = []
    private let dates = BrowserLibraryDateObserver()
    private var renderedRecords: [BrowserArchivedTab] = []
    private var spaceNames: [SpaceID: String] = [:]
    var onDownloads: (() -> Void)?
    var onSearch: (() -> Void)?
    var onRestore: ((TabID) -> Void)?
    var onDelete: ((TabID) -> Void)?
    var onClear: (() -> Void)?
    var onBack: (() -> Void)?
    var onSettings: ((Int) -> Void)?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = OrbitTokens.Radius.contentCard
        layer?.masksToBounds = true
        layer?.backgroundColor = OrbitTokens.Color.Surface.libraryBackground.cgColor
        let title = NSTextField(labelWithString: archiveText("title", "Archived Tabs"))
        title.font = OrbitTokens.Typography.commandBarInput
        title.textColor = OrbitTokens.Color.Text.primary
        profileLabel.font = OrbitTokens.Typography.menuShortcut
        profileLabel.textColor = OrbitTokens.Color.Text.secondary
        searchField.placeholderString = archiveText("search", "Search Archived Tabs…")
        searchField.maximumRecents = 0
        searchField.recentsAutosaveName = nil
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("archive-search")
        let back = NSButton(title: archiveText("back", "Back"), target: self, action: #selector(goBack))
        let clear = NSButton(title: archiveText("clear", "Clear Archive…"), target: self, action: #selector(clearAll))
        restoreButton.target = self; restoreButton.action = #selector(restore)
        deleteButton.target = self; deleteButton.action = #selector(deleteSelected)
        settings.addItems(withTitles: [archiveText("inheritTemporary", "Temporary setting · Use Default Timing"), archiveText("12hours", "12 hours"), archiveText("24hours", "24 hours"), archiveText("7days", "7 days"), archiveText("30days", "30 days")])
        settings.target = self; settings.action = #selector(changeSettings)
        settings.setAccessibilityLabel(archiveText("settingsAccessibility", "Auto Archive — Temporary Profile Setting"))
        let categories = NSSegmentedControl(labels: [archiveText("title", "Archived Tabs"), archiveText("downloads", "Downloads")], trackingMode: .selectOne, target: self, action: #selector(selectCategory(_:)))
        categories.selectedSegment = 0
        standaloneControls = [back, categories]
        let header = NSStackView(views: [back, title, NSView(), clear])
        standaloneControls = [header, categories, profileLabel, settings]
        let actions = NSStackView(views: [restoreButton, deleteButton, NSView()])
        recordActions = actions
        table.addTableColumn(NSTableColumn(identifier: .init("archive")))
        table.headerView = nil
        table.dataSource = self; table.delegate = self
        table.rowSizeStyle = .custom
        table.backgroundColor = .clear
        table.focusRingType = .exterior
        table.target = self; table.doubleAction = #selector(restore)
        table.setAccessibilityLabel(archiveText("listAccessibility", "Archived Tabs, grouped by day"))
        table.onReturn = { [weak self] in self?.restore() }
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.onEscape = { [weak self] in self?.onBack?() }
        let scroll = NSScrollView()
        scroll.documentView = table
        BrowserLibraryStyle.configure(scroll)
        scroll.drawsBackground = false
        empty.configure(symbol: BrowserLibraryCategory.archive.symbol, title: uiText("No Archived Tabs"))
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        let stack = NSStackView(views: [header, categories, profileLabel, searchField, settings, scroll, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 28)
        ])
        for view in [header, searchField, settings, scroll, actions] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        dates.onChange = { [weak self] in
            guard let self else { return }
            dateFormatter.calendar = .current; dateFormatter.timeZone = .current; dateFormatter.locale = .current
            render(renderedRecords, profileName: profileLabel.stringValue, setting: settings.indexOfSelectedItem, spaceNames: spaceNames)
        }
        updateActions()
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = (embedded ? NSColor.clear : OrbitTokens.Color.Surface.libraryBackground).cgColor }

    static func grouped(_ records: [BrowserArchivedTab], calendar: Calendar = .current) -> [Row] {
        var result: [Row] = []
        var previous: Date?
        for record in records.sorted(by: { $0.archivedAt > $1.archivedAt }) {
            let day = calendar.startOfDay(for: record.archivedAt)
            if day != previous { result.append(.day(day)); previous = day }
            result.append(.tab(record))
        }
        return result
    }

    func render(_ records: [BrowserArchivedTab], profileName: String, setting: Int, spaceNames: [SpaceID: String] = [:]) {
        renderedRecords = records
        self.spaceNames = spaceNames
        profileLabel.stringValue = profileName
        settings.selectItem(at: setting)
        let selected = selectedRecord?.id
        rows = Self.grouped(records)
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { if case let .tab(record) = $0 { return record.id == selected }; return false }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        empty.isHidden = !records.isEmpty
        recordActions?.isHidden = records.isEmpty
        empty.configure(symbol: BrowserLibraryCategory.archive.symbol, title: uiText("No Archived Tabs"), query: searchField.stringValue)
        updateActions()
    }
    var selectedRecord: BrowserArchivedTab? {
        guard rows.indices.contains(table.selectedRow), case let .tab(record) = rows[table.selectedRow] else { return nil }
        return record
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        BrowserLibraryRowView()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .day = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .tab = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .day = rows[row] { return 32 }; return 68 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier: NSUserInterfaceItemIdentifier
        if case .day = rows[row] { identifier = .init("archive-day") } else { identifier = .init("archive-tab") }
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier)
        guard let label = cell.textField else { return cell }
        switch rows[row] {
        case .day(let day):
            label.stringValue = dateFormatter.string(from: day)
            label.font = OrbitTokens.Typography.sidebarFolderTitle
            label.textColor = OrbitTokens.Color.Text.secondary
        case .tab(let record):
            label.stringValue = uiFormat("%@\n%@\n→ %@", record.tab.resolvedTitle ?? record.tab.url.host ?? archiveText("tab", "Tab"), record.tab.url.absoluteString, spaceNames[record.spaceID] ?? archiveText("currentSpace", "Current Space"))
            label.font = OrbitTokens.Typography.sidebarTabTitle
            label.textColor = OrbitTokens.Color.Text.primary
        }
        return cell
    }
    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(wrappingLabelWithString: "")
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        if identifier.rawValue == "archive-day" { label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading")) }
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dates.setAttached(window != nil)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    func controlTextDidChange(_ notification: Notification) { onSearch?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            if let row = rows.firstIndex(where: { if case .tab = $0 { return true }; return false }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                window?.makeFirstResponder(table)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelLibrarySearch(searchField, search: { onSearch?() }, close: { onBack?() })
            return true
        }
        return false
    }
    private func updateActions() { restoreButton.isEnabled = selectedRecord != nil; deleteButton.isEnabled = selectedRecord != nil }
    @objc private func selectCategory(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 { onDownloads?() }
        sender.selectedSegment = 0
    }
    @objc private func restore() { if let record = selectedRecord { onRestore?(record.id) } }
    @objc private func deleteSelected() { if let record = selectedRecord { onDelete?(record.id) } }
    @objc private func clearAll() { onClear?() }
    @objc private func goBack() { onBack?() }
    @objc private func changeSettings() { onSettings?(settings.indexOfSelectedItem) }
}

@MainActor
final class ArchiveTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 51, 117: onDelete?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}
