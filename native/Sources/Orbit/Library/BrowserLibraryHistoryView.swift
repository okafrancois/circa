import AppKit
import BrowserCore

@MainActor
final class BrowserLibraryHistoryView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Row { case day(Date), visit(BrowserHistoryVisit) }
    let searchField = NSSearchField()
    let table = ArchiveTableView()
    let deleteOptions = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    var displayedStatus: String { status.stringValue }
    private let profileLabel = NSTextField(labelWithString: "")
    private let more = NSButton(title: libraryText("more", "Load More"), target: nil, action: nil)
    private let open = NSButton(title: libraryText("open", "Open"), target: nil, action: nil)
    private let remove = NSButton(title: libraryText("deleteVisit", "Delete Visit"), target: nil, action: nil)
    private let removeSite = NSButton(title: libraryText("deleteSite", "Delete This Site…"), target: nil, action: nil)
    private(set) var rows: [Row] = []
    private var renderedVisits: [BrowserHistoryVisit] = []
    private var renderedQuery = ""
    private var renderedProfile: ProfileID?
    private let dates = BrowserLibraryDateObserver()
    private(set) var reloadCount = 0
    var onSearch: ((String) -> Void)?
    var onMore: (() -> Void)?
    var onReload: (() -> Void)?
    var onOpen: ((BrowserHistoryVisit) -> Void)?
    var onDelete: ((BrowserHistoryVisit) -> Void)?
    var onDeleteSite: ((BrowserHistoryVisit) -> Void)?
    var onDeleteRange: ((Int) -> Void)?
    var onBack: (() -> Void)?
    private let formatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.timeStyle = .short
        return formatter
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: libraryText("history", "History"))
        title.font = OrbitTokens.Typography.commandBarInput
        profileLabel.font = OrbitTokens.Typography.menuShortcut
        profileLabel.textColor = OrbitTokens.Color.Text.secondary
        searchField.placeholderString = libraryText("searchHistory", "Search History")
        searchField.maximumRecents = 0; searchField.recentsAutosaveName = nil
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("library-history-search")
        status.font = OrbitTokens.Typography.emptyStateDetail
        status.textColor = OrbitTokens.Color.Text.secondary
        let reload = NSButton(title: libraryText("refresh", "Refresh"), target: self, action: #selector(refresh))
        deleteOptions.addItems(withTitles: [libraryText("clearHistory", "Clear History…"), libraryText("lastHour", "Last Hour…"), libraryText("lastDay", "Last 24 Hours…"), libraryText("dateRange", "Date Range…"), libraryText("allTime", "All Time…")])
        deleteOptions.target = self; deleteOptions.action = #selector(deleteRange)
        deleteOptions.setAccessibilityLabel(libraryText("clearHistory", "Clear History…"))
        open.target = self; open.action = #selector(openSelected)
        remove.target = self; remove.action = #selector(deleteSelected)
        removeSite.target = self; removeSite.action = #selector(deleteSelectedSite)
        more.target = self; more.action = #selector(loadMore)
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.headerView = nil; table.dataSource = self; table.delegate = self
        table.rowSizeStyle = .custom
        table.backgroundColor = .clear
        table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityIdentifier("library-history-list")
        table.setAccessibilityLabel(libraryText("historyList", "History, grouped by day"))
        table.onReturn = { [weak self] in self?.openSelected() }
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.onEscape = { [weak self] in self?.onBack?() }
        let scroll = NSScrollView(); scroll.documentView = table
        BrowserLibraryStyle.configure(scroll)
        let header = NSStackView(views: [title, NSView(), reload, deleteOptions])
        let actions = NSStackView(views: [open, remove, removeSite, NSView(), more])
        let stack = NSStackView(views: [header, profileLabel, searchField, status, scroll, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])
        for view in [header, searchField, scroll, actions] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        dates.onChange = { [weak self] in self?.refreshDates() }
        updateActions()
    }
    required init?(coder: NSCoder) { nil }
    var selectedVisit: BrowserHistoryVisit? {
        guard rows.indices.contains(table.selectedRow), case let .visit(visit) = rows[table.selectedRow] else { return nil }
        return visit
    }
    func render(_ model: BrowserLibraryHistoryModel, profileName: String) {
        profileLabel.stringValue = profileName
        if searchField.stringValue != model.query { searchField.stringValue = model.query }
        if renderedVisits != model.visits || renderedProfile != model.profileID || renderedQuery != model.displayedQuery {
            let preservePosition = renderedProfile == model.profileID && renderedQuery == model.displayedQuery
            renderedProfile = model.profileID
            renderedQuery = model.displayedQuery
            renderedVisits = model.visits
            rebuildRows(preservePosition: preservePosition)
        }
        status.stringValue = model.hasError ? libraryText("unavailable", "History is unavailable. Try Refresh.") : model.isLoading && !model.isDebouncing ? libraryText("loading", "Loading…") : model.visits.isEmpty ? (model.query.isEmpty ? libraryText("emptyHistory", "No History for This Profile") : libraryText("noResults", "No Results")) : ""
        more.isEnabled = model.hasMore && !model.isLoading
        deleteOptions.isEnabled = model.profileID != nil
        updateActions()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dates.setAttached(window != nil)
    }
    func refreshDates() {
        formatter.calendar = .current; formatter.timeZone = .current; formatter.locale = .current
        timeFormatter.calendar = .current; timeFormatter.timeZone = .current; timeFormatter.locale = .current
        rebuildRows(preservePosition: true)
    }
    private func rebuildRows(preservePosition: Bool) {
        let scroll = table.enclosingScrollView
        let origin = preservePosition ? scroll?.contentView.bounds.origin ?? .zero : .zero
        var probe = origin
        var top = table.row(at: probe)
        // AppKit's floating day heading occupies the viewport's top even after scrolling.
        // Anchor the first visit below it, rather than treating that heading as a data row.
        if rows.indices.contains(top), case .day = rows[top] {
            probe.y += table.rect(ofRow: top).height + table.intercellSpacing.height + 1
            top = table.row(at: probe)
        }
        let anchor: UUID? = rows.indices.contains(top) ? {
            if case let .visit(visit) = rows[top] { return visit.id }; return nil
        }() : nil
        let delta = top >= 0 ? origin.y - table.rect(ofRow: top).minY : 0
        let selection = preservePosition ? selectedVisit?.id : nil
        rows = []
        var previous: Date?
        for visit in renderedVisits {
            let day = Calendar.current.startOfDay(for: visit.visitedAt)
            if previous != day { rows.append(.day(day)); previous = day }
            rows.append(.visit(visit))
        }
        table.reloadData(); reloadCount += 1
        func index(_ id: UUID) -> Int? {
            rows.firstIndex { if case let .visit(visit) = $0 { return visit.id == id }; return false }
        }
        if let selection, let row = index(selection) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        if let scroll {
            table.layoutSubtreeIfNeeded()
            let y = anchor.flatMap(index).map { table.rect(ofRow: $0).minY + delta } ?? origin.y
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: min(max(0, y), max(0, table.bounds.height - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .visit = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .day = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .day = rows[row] { return 32 }; return 52 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier({ if case .day = rows[row] { return "history-day" }; return "history-visit" }())
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier)
        guard let label = cell.textField else { return cell }
        switch rows[row] {
        case .day(let day):
            label.stringValue = formatter.string(from: day)
            label.font = OrbitTokens.Typography.sidebarFolderTitle
            label.textColor = OrbitTokens.Color.Text.secondary
            label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        case .visit(let visit):
            label.stringValue = uiFormat("%@ · %@\n%@", timeFormatter.string(from: visit.visitedAt), visit.title.isEmpty ? visit.url.host ?? visit.url.absoluteString : visit.title, visit.url.absoluteString)
            label.font = OrbitTokens.Typography.sidebarTabTitle
            label.textColor = OrbitTokens.Color.Text.primary
        }
        return cell
    }
    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(); cell.identifier = identifier
        let label = NSTextField(wrappingLabelWithString: ""); label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    private func updateActions() {
        open.isEnabled = selectedVisit != nil; remove.isEnabled = selectedVisit != nil
        removeSite.isEnabled = selectedVisit?.url.host != nil
    }
    func controlTextDidChange(_ notification: Notification) { onSearch?(searchField.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelLibrarySearch(searchField, search: { onSearch?(searchField.stringValue) }, close: { onBack?() })
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            if let index = rows.firstIndex(where: { if case .visit = $0 { return true }; return false }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                window?.makeFirstResponder(table)
            }
            return true
        }
        return false
    }
    @objc private func openSelected() { if let visit = selectedVisit { onOpen?(visit) } }
    @objc private func deleteSelected() { if let visit = selectedVisit { onDelete?(visit) } }
    @objc private func deleteSelectedSite() { if let visit = selectedVisit { onDeleteSite?(visit) } }
    @objc private func loadMore() { onMore?() }
    @objc private func refresh() { onReload?() }
    @objc private func deleteRange() { let index = deleteOptions.indexOfSelectedItem; deleteOptions.selectItem(at: 0); if index > 0 { onDeleteRange?(index) } }
}
