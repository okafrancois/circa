import AppKit
import BrowserShell
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
    private var contentStack: NSStackView?
    func setLibraryEmbedded() {
        embedded = true
        contentStack?.spacing = 8
        standaloneControls.forEach { $0.isHidden = true }
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    private let profileLabel = NSTextField(labelWithString: "")
    private let empty = BrowserLibraryEmptyView()
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
    var favicon: (URL) -> NSImage? = { _ in nil }
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("MMMMd"); formatter.timeStyle = .none
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
        profileLabel.font = BrandTextStyle.caption.font(size: 13)
        profileLabel.textColor = OrbitTokens.Color.Text.secondary
        searchField.placeholderString = archiveText("search", "Search Archive…")
        searchField.maximumRecents = 0
        searchField.recentsAutosaveName = nil
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("archive-search")
        let back = NSButton(title: archiveText("back", "Back"), target: self, action: #selector(goBack))
        let clear = NSButton(title: archiveText("clear", "Clear Archive…"), target: self, action: #selector(clearAll))
        for control in [back, clear, settings] { control.font = BrandTextStyle.ui.font(size: 13) }
        settings.addItems(withTitles: [archiveText("inheritTemporary", "Temporary setting · Use Default Timing"), archiveText("12hours", "12 hours"), archiveText("24hours", "24 hours"), archiveText("7days", "7 days"), archiveText("30days", "30 days")])
        settings.target = self; settings.action = #selector(changeSettings)
        settings.setAccessibilityLabel(archiveText("settingsAccessibility", "Auto Archive — Temporary Profile Setting"))
        let categories = NSSegmentedControl(labels: [archiveText("title", "Archived Tabs"), archiveText("downloads", "Downloads")], trackingMode: .selectOne, target: self, action: #selector(selectCategory(_:)))
        categories.selectedSegment = 0
        standaloneControls = [back, categories]
        let header = NSStackView(views: [back, title, NSView(), clear])
        standaloneControls = [header, categories, profileLabel, settings]
        table.addTableColumn(NSTableColumn(identifier: .init("archive")))
        table.headerView = nil
        table.dataSource = self; table.delegate = self
        table.style = .plain
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.focusRingType = .exterior
        table.target = self; table.doubleAction = #selector(restore)
        table.setAccessibilityLabel(archiveText("listAccessibility", "Archived Tabs, grouped by day"))
        table.onReturn = { [weak self] in self?.restore() }
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.onEscape = { [weak self] in self?.onBack?() }
        table.onMenuForRow = { [weak self] row in self?.contextMenu(for: row) }
        let scroll = NSScrollView()
        scroll.documentView = table
        BrowserLibraryStyle.configure(scroll)
        scroll.drawsBackground = false
        empty.configure(symbol: BrowserLibraryCategory.archive.symbol, title: uiText("No Archived Tabs"), largeGlyph: true)
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        let search = NSStackView(views: [searchField, BrowserLibraryFilterButton()])
        search.spacing = 4
        let stack = NSStackView(views: [header, categories, profileLabel, search, settings, scroll])
        contentStack = stack
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
        for view in [header, search, settings, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        dates.onChange = { [weak self] in
            guard let self else { return }
            dateFormatter.calendar = .current; dateFormatter.timeZone = .current; dateFormatter.locale = .current
            render(renderedRecords, profileName: profileLabel.stringValue, setting: settings.indexOfSelectedItem, spaceNames: spaceNames)
        }
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
        empty.configure(symbol: BrowserLibraryCategory.archive.symbol, title: uiText("No Archived Tabs"), query: searchField.stringValue, largeGlyph: true)
    }
    var selectedRecord: BrowserArchivedTab? {
        guard rows.indices.contains(table.selectedRow), case let .tab(record) = rows[table.selectedRow] else { return nil }
        return record
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        BrowserLibraryRowView()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .tab = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .day = rows[row] { return 28 }; return 56 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier: NSUserInterfaceItemIdentifier
        if case .day = rows[row] { identifier = .init("archive-day") } else { identifier = .init("archive-tab") }
        if case .day(let day) = rows[row] {
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
            cell.identifier = identifier
            let label = cell.textField ?? NSTextField(labelWithString: "")
            if label.superview == nil {
                cell.addSubview(label); cell.textField = label
                label.translatesAutoresizingMaskIntoConstraints = false
                label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            label.stringValue = Calendar.current.isDateInToday(day) ? uiText("Today")
                : Calendar.current.isDateInYesterday(day) ? uiText("Yesterday") : dateFormatter.string(from: day)
            label.font = BrandTextStyle.ui.font(size: 13, weight: .bold)
            label.textColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.65)
            return cell
        }
        guard case .tab(let record) = rows[row] else { return nil }
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserArchiveCell) ?? BrowserArchiveCell()
        cell.identifier = identifier
        cell.configure(record, icon: favicon(record.tab.url))
        return cell
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dates.setAttached(window != nil)
    }
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
    func contextMenu(for row: Int) -> NSMenu? {
        guard rows.indices.contains(row), case .tab(let record) = rows[row] else { return nil }
        let menu = NSMenu()
        for (title, action) in [(uiText("Restore"), #selector(restoreFromMenu(_:))), (uiText("Delete"), #selector(deleteFromMenu(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = record.id
            menu.addItem(item)
        }
        return menu
    }
    private func menuRecord(_ sender: NSMenuItem) -> TabID? {
        guard let id = sender.representedObject as? TabID,
              rows.contains(where: { if case .tab(let record) = $0 { return record.id == id }; return false }) else { return nil }
        return id
    }
    @objc private func restoreFromMenu(_ sender: NSMenuItem) { if let id = menuRecord(sender) { onRestore?(id) } }
    @objc private func deleteFromMenu(_ sender: NSMenuItem) { if let id = menuRecord(sender) { onDelete?(id) } }
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
    var onMenuForRow: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard let menu = onMenuForRow?(row) else { return super.menu(for: event) }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menu
    }
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

@MainActor
final class BrowserArchiveCell: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = BrandTextStyle.ui.font(size: 14, weight: .medium)
        detailLabel.font = BrandTextStyle.mono.font(size: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, titleLabel, detailLabel] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        textField = titleLabel; imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2)
        ])
        updateColors()
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ record: BrowserArchivedTab, icon image: NSImage?) {
        titleLabel.stringValue = record.tab.resolvedTitle ?? record.tab.url.host ?? uiText("Tab")
        detailLabel.stringValue = record.tab.url.absoluteString
        icon.image = image ?? OrbitIcon.image(sfName: "globe", pointSize: 16, accessibilityDescription: nil)
        icon.contentTintColor = image == nil ? BrowserLibraryStyle.foreground.withAlphaComponent(0.5) : nil
        setAccessibilityLabel(titleLabel.stringValue)
        setAccessibilityHelp(detailLabel.stringValue)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        titleLabel.textColor = BrowserLibraryStyle.foreground
        detailLabel.textColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.55)
    }
}
