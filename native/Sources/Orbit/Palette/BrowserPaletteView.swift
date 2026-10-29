import AppKit

/// Transparent hit shield: outside clicks dismiss without reaching the underlying document.
@MainActor
final class BrowserPaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let input: NSTextField = PaletteInputField()
    let panel = NSView()
    let material = OrbitPaletteBackdropView()
    private let materialTint = NSView()
    private let materialObservers = OrbitWorkspaceObservers()
    private(set) var usesMaterial = !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    private let panelShadow = CALayer()
    let scroll = NSScrollView()
    let searchIcon = NSImageView()
    let divider = NSView()
    let infoButton = NSButton()
    let scopeLabel = NSTextField(labelWithString: "")
    let siteHint = NSTextField(labelWithString: "")
    private let infoPopover = NSPopover()
    private(set) var inputSymbol = "magnifyingglass"
    var siteSearchHint: BrowserPaletteSiteSearch? {
        didSet {
            guard oldValue != siteSearchHint else { return }
            siteHint.stringValue = siteSearchHint == nil ? "" : uiText("Tab to search")
            siteHint.isHidden = siteSearchHint == nil
            needsLayout = true
        }
    }
    private var siteSearch: BrowserPaletteSiteSearch?
    private var suppressCompletion = false
    private var deletionEdit = false
    static let scopedSearchSpring = OrbitTokens.Spring(response: 0.7, dampingFraction: 0.9)
    private let innerStroke = NSView()
    private let list = PaletteTableView()
    private enum Entry: Equatable {
        case header(BrowserPaletteSection)
        case result(Int)
    }
    private var entries: [Entry] = []
    private var results: [BrowserPaletteResult] = []
    private var resultRows: [Int] = []
    private var selectedIndex = -1
    private var selectedResult: BrowserPaletteResult?
    private var announcedResultCount = 0
    private var countAnnouncementTask: Task<Void, Never>?
    var onAccessibilityAnnouncement: ((String) -> Void)?
    private var symbolImages: [String: NSImage] = [:]
    var onQuery: ((String) -> Void)?
    var onMove: ((Int) -> Void)?
    var onAccept: ((NSEvent.ModifierFlags) -> Void)?
    var onSelect: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    var onCancel: (() -> Bool)?
    var onTab: (() -> Bool)?
    var onEmptyBackspace: (() -> Bool)?
    var accent = OrbitTokens.ThemeAccent.defaultPurple.selection
    var favicons: [String: NSImage] = [:]
    override var isFlipped: Bool { true }
    override var isHidden: Bool {
        didSet {
            if isHidden {
                infoPopover.close()
                panel.layer?.removeAnimation(forKey: "palette.scoped-search")
                panelShadow.removeAnimation(forKey: "palette.scoped-search")
                countAnnouncementTask?.cancel()
                countAnnouncementTask = nil
            }
        }
    }
    func waitForAccessibilityAnnouncements() async { await countAnnouncementTask?.value }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        wantsLayer = true
        panel.wantsLayer = true
        panel.layer?.cornerRadius = OrbitTokens.Radius.commandBar
        panel.layer?.masksToBounds = false
        layer?.addSublayer(panelShadow)
        addSubview(panel)
        innerStroke.wantsLayer = true
        innerStroke.layer?.cornerRadius = OrbitTokens.Radius.commandBar - 0.5
        innerStroke.setAccessibilityElement(false)
        panel.addSubview(material)
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = OrbitTokens.Radius.commandBar
        material.layer?.masksToBounds = true
        material.setAccessibilityElement(false)
        materialTint.wantsLayer = true
        materialTint.layer?.cornerRadius = OrbitTokens.Radius.commandBar
        materialTint.setAccessibilityElement(false)
        panel.addSubview(materialTint)
        panel.addSubview(innerStroke)
        input.isBordered = false
        input.isBezeled = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = OrbitTokens.Typography.commandBarInput
        input.cell?.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.placeholderString = uiText("Search or Enter URL…")
        input.placeholderAttributedString = NSAttributedString(string: uiText("Search or Enter URL…"), attributes: [
            .font: OrbitTokens.Typography.commandBarInput, .foregroundColor: OrbitTokens.Color.Text.placeholder
        ])
        input.delegate = self
        input.setAccessibilityLabel(uiText("Search or Enter URL"))
        input.setAccessibilityIdentifier("palette-input")
        (input as? PaletteInputField)?.onReturn = { [weak self] event in
            self?.onAccept?(event.modifierFlags)
        }
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityLabel(uiText("Command Bar"))
        panel.addSubview(input)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.setAccessibilityElement(false)
        panel.addSubview(searchIcon)
        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: uiText("About suggestions"))
        infoButton.isBordered = false
        infoButton.bezelStyle = .circular
        infoButton.target = self
        infoButton.action = #selector(showSuggestionInfo(_:))
        infoButton.setAccessibilityLabel(uiText("About suggestions"))
        infoButton.setAccessibilityIdentifier("palette-suggestion-info")
        panel.addSubview(infoButton)
        scopeLabel.font = OrbitTokens.Typography.commandBarRowTitle
        scopeLabel.wantsLayer = true
        scopeLabel.layer?.cornerRadius = OrbitTokens.Radius.commandBarRow
        scopeLabel.alignment = .center
        scopeLabel.isHidden = true
        panel.addSubview(scopeLabel)
        siteHint.font = OrbitTokens.Typography.commandBarAccessory
        siteHint.textColor = OrbitTokens.Color.Text.commandBarSecondary
        siteHint.isHidden = true
        panel.addSubview(siteHint)
        divider.wantsLayer = true
        divider.setAccessibilityElement(false)
        panel.addSubview(divider)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = list
        panel.addSubview(scroll)
        list.style = .plain
        list.headerView = nil
        list.backgroundColor = .clear
        list.focusRingType = .none
        list.selectionHighlightStyle = .none
        list.intercellSpacing = .zero
        list.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        list.allowsEmptySelection = true
        list.allowsMultipleSelection = false
        list.usesAutomaticRowHeights = false
        list.floatsGroupRows = false
        list.setAccessibilityLabel(uiText("Command Bar Results"))
        list.setAccessibilityIdentifier("palette-results")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column)
        list.dataSource = self
        list.delegate = self
        list.onPressRow = { [weak self] row in self?.press(row: row) }
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMaterial() }
        }
        materialObservers.tokens.append((center, observer))
        refreshColors()
    }
    required init?(coder: NSCoder) { nil }

    static func panelFrame(in size: NSSize, resultCount: Int = 5) -> NSRect {
        let m = OrbitTokens.Metrics.CommandBar.self
        let count = min(5, max(0, resultCount))
        let preferredHeight = m.searchRowHeight + m.firstRowGap + CGFloat(count) * m.rowPitch
            - (count > 0 ? m.rowPitch - m.rowHeight : 0) + m.bottomPadding
        let top = max(m.rowInsetX, min(m.top(windowHeight: size.height), size.height - m.searchRowHeight - m.rowInsetX))
        let height = min(preferredHeight, max(m.searchRowHeight, size.height - top - m.rowInsetX))
        let width = min(m.width, max(0, size.width - 2 * m.rowInsetX))
        return NSRect(x: (size.width - width) / 2, y: top, width: width, height: height)
    }

    override func layout() {
        super.layout()
        let m = OrbitTokens.Metrics.CommandBar.self
        panel.frame = Self.panelFrame(in: bounds.size, resultCount: results.count)
        panelShadow.frame = panel.frame
        panelShadow.shadowPath = CGPath(roundedRect: panelShadow.bounds, cornerWidth: OrbitTokens.Radius.commandBar,
                                       cornerHeight: OrbitTokens.Radius.commandBar, transform: nil)
        material.frame = panel.bounds
        materialTint.frame = panel.bounds
        innerStroke.frame = panel.bounds.insetBy(dx: 0.5, dy: 0.5)
        // Panel uses unflipped coordinates. Its top and input stay fixed while results change.
        let inputHeight = input.intrinsicContentSize.height
        let scopeWidth = siteSearch == nil ? 0 : min(180, ceil(scopeLabel.intrinsicContentSize.width) + 20)
        scopeLabel.frame = NSRect(x: m.titleOriginX, y: panel.bounds.height - 45, width: scopeWidth, height: 26)
        let inputX = m.titleOriginX + (scopeWidth > 0 ? scopeWidth + 10 : 0)
        let trailing: CGFloat = siteHint.isHidden ? 48 : 144
        input.frame = NSRect(x: inputX, y: panel.bounds.height - m.searchRowHeight / 2 - inputHeight / 2,
                             width: max(0, panel.bounds.width - inputX - trailing), height: inputHeight)
        infoButton.frame = NSRect(x: panel.bounds.width - 46, y: panel.bounds.height - 44, width: 24, height: 24)
        siteHint.frame = NSRect(x: panel.bounds.width - 144, y: panel.bounds.height - 43, width: 96, height: 20)
        searchIcon.frame = NSRect(x: 23, y: panel.bounds.height - m.searchRowHeight / 2 - 8, width: 16, height: 16)
        divider.frame = NSRect(x: m.rowInsetX, y: panel.bounds.height - m.searchRowHeight,
                               width: max(0, panel.bounds.width - 2 * m.rowInsetX), height: 1 / (window?.backingScaleFactor ?? 2))
        scroll.frame = NSRect(x: m.rowInsetX, y: m.bottomPadding, width: max(0, panel.bounds.width - 2 * m.rowInsetX),
                              height: max(0, panel.bounds.height - m.searchRowHeight - m.firstRowGap - m.bottomPadding))
        resizeList()
    }

    /// Synchronous: the controller can measure render plus layoutSubtreeIfNeeded in one signpost.
    func render(_ results: [BrowserPaletteResult], selected: Int) {
        scroll.hasVerticalScroller = results.count > 5
        var nextEntries: [Entry] = []
        var nextRows: [Int] = []
        nextEntries.reserveCapacity(results.count + BrowserPaletteSection.allCases.count)
        nextRows.reserveCapacity(results.count)
        for index in results.indices {
            nextRows.append(nextEntries.count)
            nextEntries.append(.result(index))
        }
        let countChanged = self.results.count != results.count
        self.results = results
        resultRows = nextRows
        let oldCount = entries.count
        let sharedCount = zip(entries, nextEntries).prefix { $0 == $1 }.count
        let structureChanged = sharedCount != max(oldCount, nextEntries.count)
        entries = nextEntries
        if countChanged { needsLayout = true; layoutSubtreeIfNeeded() }
        if structureChanged {
            // Retain the unchanged prefix, including its live cells, when filtering a section.
            list.beginUpdates()
            if sharedCount < oldCount {
                list.removeRows(at: IndexSet(integersIn: sharedCount..<oldCount), withAnimation: [])
            }
            if sharedCount < entries.count {
                list.insertRows(at: IndexSet(integersIn: sharedCount..<entries.count), withAnimation: [])
            }
            list.endUpdates()
            resizeList()
        }
        // Refresh all cached rows, including prepared offscreen views. makeIfNecessary stays false;
        // no offscreen cell is allocated and the bounded result cap keeps this inexpensive.
        for row in entries.indices {
            if let cell = list.view(atColumn: 0, row: row, makeIfNecessary: false) as? PaletteResultCell {
                configure(cell, at: row, selected: selected)
            }
            if let rowView = list.rowView(atRow: row, makeIfNecessary: false) as? PaletteTableRowView {
                configure(rowView, at: row)
            }
        }
        updateSelection(selected)
    }

    func updateSelection(_ selected: Int) {
        let oldIndex = selectedIndex
        let oldResult = selectedResult
        let oldCount = announcedResultCount
        selectedIndex = results.indices.contains(selected) ? selected : -1
        selectedResult = selectedIndex >= 0 ? results[selectedIndex] : nil
        announcedResultCount = results.count
        let symbol = selectedResult?.inputSymbol ?? "magnifyingglass"
        inputSymbol = symbol
        if symbolImages[symbol] == nil { symbolImages[symbol] = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let image = selectedResult.flatMap { result in
            result.section == .tabs || result.section == .pinned ? favicons[result.id] : nil
        }
        let inputImage = image ?? symbolImages[symbol]
        if searchIcon.image !== inputImage { searchIcon.image = inputImage }
        searchIcon.contentTintColor = image == nil ? OrbitTokens.Color.Text.commandBarPrimary : nil
        infoButton.isHidden = siteSearch != nil
        let row = selectedIndex >= 0 ? resultRows[selectedIndex] : -1
        list.selectRowIndexes(row >= 0 ? IndexSet(integer: row) : [], byExtendingSelection: false)
        if oldIndex != selectedIndex { refreshSelection(at: oldIndex) }
        refreshSelection(at: selectedIndex)
        if row >= 0 { list.scrollRowToVisible(row) }
        let selectionChanged = oldIndex != selectedIndex || oldResult?.id != selectedResult?.id
        if selectionChanged {
            countAnnouncementTask?.cancel()
            NSAccessibility.post(element: list, notification: .selectedRowsChanged)
            if let result = selectedResult {
                announce(uiFormat("%@, %@, %@, %ld of %ld", result.title, result.section.localizedTitle, result.detail, selectedIndex + 1, results.count))
                return
            }
        }
        if oldCount != announcedResultCount {
            countAnnouncementTask?.cancel()
            countAnnouncementTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let self, !isHidden else { return }
                announce(uiFormat("%ld results", results.count), priority: .low)
            }
        }
    }

    private func announce(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
        onAccessibilityAnnouncement?(text)
        NSAccessibility.post(element: input, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: priority.rawValue
        ])
    }

    private func refreshSelection(at index: Int) {
        guard resultRows.indices.contains(index),
              let cell = list.view(atColumn: 0, row: resultRows[index], makeIfNecessary: false) as? PaletteResultCell else { return }
        cell.apply(selected: index == selectedIndex, accent: accent, usesMaterial: usesMaterial)
    }

    private var visibleRows: Range<Int> {
        let range = list.rows(in: list.visibleRect)
        guard range.location != NSNotFound else { return 0..<0 }
        return range.location..<min(entries.count, NSMaxRange(range))
    }

    private func resizeList() {
        let m = OrbitTokens.Metrics.CommandBar.self
        let height = entries.reduce(CGFloat.zero) { height, entry in
            switch entry {
            case .header: height + m.iconTileSize
            case .result: height + m.rowPitch
            }
        }
        list.frame.size = NSSize(width: scroll.contentSize.width, height: max(height, scroll.contentSize.height))
        list.tableColumns.first?.width = list.bounds.width
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch entries[row] {
        case .header: OrbitTokens.Metrics.CommandBar.iconTileSize
        case .result: OrbitTokens.Metrics.CommandBar.rowPitch
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = entries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .result = entries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch entries[row] {
        case .header(let section):
            let identifier = NSUserInterfaceItemIdentifier("palette-section")
            let header = (tableView.makeView(withIdentifier: identifier, owner: nil) as? PaletteSectionCell) ?? PaletteSectionCell()
            header.identifier = identifier
            header.label.stringValue = section.localizedTitle
            return header
        case .result:
            let identifier = NSUserInterfaceItemIdentifier("palette-result")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? PaletteResultCell) ?? PaletteResultCell()
            cell.identifier = identifier
            configure(cell, at: row, selected: selectedIndex)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("palette-row")
        let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? PaletteTableRowView) ?? PaletteTableRowView()
        view.identifier = identifier
        configure(view, at: row)
        return view
    }

    private func configure(_ rowView: PaletteTableRowView, at row: Int) {
        switch entries[row] {
        case .header(let section):
            rowView.setAccessibilityRole(.group)
            rowView.setAccessibilityLabel(section.localizedTitle)
            rowView.setAccessibilityIdentifier("palette-section-\(row)")
            rowView.onPress = nil
        case .result(let index):
            let result = results[index]
            rowView.setAccessibilityRole(.row)
            rowView.setAccessibilityLabel(result.title + ", " + result.section.localizedTitle + ", " + result.detail)
            rowView.setAccessibilityIdentifier("palette-result-\(index)")
            rowView.onPress = { [weak self] in self?.press(row: row) }
        }
    }

    private func configure(_ cell: PaletteResultCell, at row: Int, selected: Int) {
        guard case .result(let index) = entries[row] else { return }
        let result = results[index]
        var image = favicons[result.id]
        let usesFavicon = image != nil
        if image == nil {
            image = symbolImages[result.symbol]
            if image == nil {
                image = NSImage(systemSymbolName: result.symbol, accessibilityDescription: nil)
                symbolImages[result.symbol] = image
            }
        }
        cell.configure(result: result, image: image, usesFavicon: usesFavicon,
                       showsDetails: !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        cell.apply(selected: index == selected, accent: accent, usesMaterial: usesMaterial)
    }

    private func press(row: Int) {
        guard entries.indices.contains(row), case .result(let index) = entries[row] else { return }
        updateSelection(index)
        onSelect?(index)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
        for row in entries.indices {
            if let cell = list.view(atColumn: 0, row: row, makeIfNecessary: false) as? PaletteResultCell {
                configure(cell, at: row, selected: selectedIndex)
            }
        }
    }
    func refreshMaterial(reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
        usesMaterial = !reduceTransparency
        refreshColors()
        for row in entries.indices {
            if let cell = list.view(atColumn: 0, row: row, makeIfNecessary: false) as? PaletteResultCell {
                configure(cell, at: row, selected: selectedIndex)
            }
        }
    }

    private func refreshColors() {
        material.isHidden = !usesMaterial
        materialTint.isHidden = !usesMaterial
        materialTint.layer?.backgroundColor = OrbitTokens.Color.Surface.commandBarTint.resolvedCGColor(for: effectiveAppearance)
        panel.layer?.backgroundColor = (usesMaterial ? NSColor.clear : OrbitTokens.Color.Surface.commandBar).resolvedCGColor(for: effectiveAppearance)
        OrbitTokens.Shadow.commandBar.apply(to: panelShadow, isFlipped: true, appearance: effectiveAppearance)
        input.textColor = OrbitTokens.Color.Text.commandBarPrimary
        searchIcon.contentTintColor = OrbitTokens.Color.Text.commandBarPrimary
        infoButton.contentTintColor = OrbitTokens.Color.Text.commandBarSecondary
        scopeLabel.textColor = OrbitTokens.Color.Text.onAccent
        scopeLabel.layer?.backgroundColor = accent.resolvedCGColor(for: effectiveAppearance)
        divider.layer?.backgroundColor = OrbitTokens.Color.Line.commandBarHairline.resolvedCGColor(for: effectiveAppearance)
        panel.layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        panel.layer?.borderColor = (usesMaterial ? OrbitTokens.Color.Line.commandBarMaterialOuterStroke : OrbitTokens.Color.Line.commandBarOuterStroke).resolvedCGColor(for: effectiveAppearance)
        innerStroke.layer?.borderWidth = usesMaterial ? 1 : 1 / (window?.backingScaleFactor ?? 2)
        innerStroke.layer?.borderColor = (usesMaterial ? OrbitTokens.Color.Line.commandBarMaterialInnerStroke : OrbitTokens.Color.Line.commandBarInnerStroke).resolvedCGColor(for: effectiveAppearance)
    }
    func completeURL(for result: BrowserPaletteResult, draft: String) {
        guard !suppressCompletion, siteSearchHint == nil, !draft.isEmpty,
              !draft.contains(where: \.isWhitespace), result.section != .search,
              result.section != .commands, let url = result.url,
              let editor = input.currentEditor() as? NSTextView, !editor.hasMarkedText(),
              editor.selectedRange().location >= (draft as NSString).length else { return }
        let full = BrowserPaletteRanking.displayURL(url)
        guard full.count > draft.count, full.lowercased().hasPrefix(draft.lowercased()) else { return }
        input.stringValue = draft + full.dropFirst(draft.count)
        editor.string = input.stringValue
        editor.setSelectedRange(NSRange(location: (draft as NSString).length,
                                        length: (input.stringValue as NSString).length - (draft as NSString).length))
    }

    func setSiteSearch(_ site: BrowserPaletteSiteSearch?, animated: Bool) {
        let changed = (siteSearch == nil) != (site == nil)
        siteSearch = site
        scopeLabel.stringValue = site.map { uiText($0.name) } ?? ""
        scopeLabel.layer?.backgroundColor = accent.resolvedCGColor(for: effectiveAppearance)
        scopeLabel.isHidden = site == nil
        let placeholder = site.map { uiFormat("Search %@", uiText($0.name)) } ?? uiText("Search or Enter URL…")
        input.placeholderString = placeholder
        input.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: OrbitTokens.Typography.commandBarInput, .foregroundColor: OrbitTokens.Color.Text.placeholder
        ])
        input.setAccessibilityLabel(placeholder)
        // AppKit's active field editor caches its placeholder. Rebind it at a scope boundary;
        // the controller clears the query immediately afterward, and IME never enters here.
        if !isHidden, input.currentEditor() != nil {
            window?.makeFirstResponder(nil)
            window?.makeFirstResponder(input)
        }
        infoPopover.close()
        needsLayout = true
        layoutSubtreeIfNeeded()
        panel.layer?.removeAnimation(forKey: "palette.scoped-search")
        panelShadow.removeAnimation(forKey: "palette.scoped-search")
        guard changed, animated, !isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              panel.frame.maxY < bounds.height - OrbitTokens.Metrics.CommandBar.rowInsetX else { return }
        // The subscription bounces only on nil <-> scoped state, not each query.
        // Keep the final model transform at identity so interruption and dismissal are immediate.
        for target in [panel.layer, panelShadow].compactMap({ $0 }) {
            let frame = target.frame
            target.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            target.frame = frame
            let animation = Self.scopedSearchSpring.animation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.95, 0.95, 1))
            animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            target.add(animation, forKey: "palette.scoped-search")
        }
    }

    @objc private func showSuggestionInfo(_ sender: NSButton) {
        let controller = NSViewController()
        let label = NSTextField(wrappingLabelWithString: uiText("Suggestions come from your open tabs, bookmarks, and history. Web searches use your selected search engine."))
        label.frame = NSRect(x: 16, y: 16, width: 280, height: 72)
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 312, height: 104))
        controller.view.addSubview(label)
        infoPopover.contentViewController = controller
        infoPopover.behavior = .transient
        infoPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { onDismiss?() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Command-Return does not reliably become insertNewline in the field editor.
        if input.currentEditor() != nil, (input as? PaletteInputField)?.acceptReturn(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        suppressCompletion = deletionEdit
        deletionEdit = false
        onQuery?(input.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === input, !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): onMove?(1)
        case #selector(NSResponder.moveUp(_:)): onMove?(-1)
        case #selector(NSResponder.insertTab(_:)): if onTab?() != true { onMove?(1) }
        case #selector(NSResponder.insertBacktab(_:)): onMove?(-1)
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            // Direct field-editor dispatch need not set NSApp.currentEvent (hidden-window tests).
            var flags = NSApp.currentEvent.flatMap { $0.type == .keyDown ? $0.modifierFlags : nil } ?? []
            if selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) { flags.insert(.option) }
            if selector == #selector(NSResponder.insertLineBreak(_:)) { flags.insert(.control) }
            onAccept?(flags)
        case #selector(NSResponder.deleteBackward(_:)):
            if textView.string.isEmpty, onEmptyBackspace?() == true { return true }
            deletionEdit = true
            return false
        case #selector(NSResponder.cancelOperation(_:)): if onCancel?() != true { onDismiss?() }
        default: return false
        }
        return true
    }
}

@MainActor
private final class PaletteInputField: NSTextField {
    var onReturn: ((NSEvent) -> Void)?
    func acceptReturn(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              (currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
        onReturn?(event)
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if currentEditor() != nil, acceptReturn(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !acceptReturn(event) { super.keyDown(with: event) }
    }
}

@MainActor
private final class PaletteTableView: NSTableView {
    var onPressRow: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {
        // Selection belongs to the input's controller; clicks must not end field editing.
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onPressRow?(row) }
    }
}

@MainActor
private final class PaletteTableRowView: NSTableRowView {
    var onPress: (() -> Void)?
    override func drawSelection(in dirtyRect: NSRect) {}
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}

@MainActor
private final class PaletteSectionCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = OrbitTokens.Typography.commandBarAccessory
        label.textColor = OrbitTokens.Color.Text.commandBarSecondary
        label.setAccessibilityElement(false)
        setAccessibilityElement(false)
        addSubview(label)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let inset = OrbitTokens.Metrics.CommandBar.iconTileInsetX
        label.frame = NSRect(x: inset, y: 0, width: max(0, bounds.width - 2 * inset), height: bounds.height)
    }
}

@MainActor
final class PaletteResultCell: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let actionLabel = NSTextField(labelWithString: "")
    let shortcutLabel = NSTextField(labelWithString: "")
    let actionIcon = NSImageView()
    let icon = NSImageView()
    let background = NSView()
    let iconTile = NSView()
    let accessory = NSView()
    private var resultID: String?
    private var usesFavicon = false
    private var isSelectedResult = false
    private var isHovered = false
    private var selectionAccent = NSColor.clear
    private var usesMaterial = true
    private var hoverArea: NSTrackingArea?
    private var showsTabAction = false
    private var showsRestoreAction = false
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.wantsLayer = true
        background.layer?.cornerRadius = OrbitTokens.Radius.commandBarRow
        background.setAccessibilityElement(false)
        addSubview(background)
        titleLabel.font = OrbitTokens.Typography.commandBarRowTitle
        detailLabel.font = OrbitTokens.Typography.commandBarAccessory
        actionLabel.font = OrbitTokens.Typography.commandBarAccessory
        shortcutLabel.font = OrbitTokens.Typography.commandBarAccessory
        actionIcon.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.alignment = .left
        actionLabel.alignment = .right
        actionLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.alignment = .right
        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = OrbitTokens.Radius.commandBarIconTile
        accessory.wantsLayer = true
        accessory.layer?.cornerRadius = OrbitTokens.Radius.commandBarIconTile
        addSubview(iconTile)
        addSubview(accessory)
        setAccessibilityElement(false)
        for view in [titleLabel, detailLabel, actionLabel, shortcutLabel, icon, actionIcon] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func configure(result: BrowserPaletteResult, image: NSImage?, usesFavicon: Bool, showsDetails: Bool = true) {
        if resultID != result.id { isHovered = false; resultID = result.id }
        self.usesFavicon = usesFavicon
        if titleLabel.stringValue != result.title {
            titleLabel.stringValue = result.title
            needsLayout = true
        }
        showsTabAction = result.section == .tabs || { if case .tab = result.action { return true }; return false }()
        showsRestoreAction = result.section == .archive
        let detail = showsDetails && result.section != .commands && !result.detail.isEmpty && result.detail != result.title
            ? "— " + result.detail : ""
        if detailLabel.stringValue != detail {
            detailLabel.stringValue = detail
            needsLayout = true
        }
        actionLabel.stringValue = result.actionLabel
        shortcutLabel.stringValue = result.shortcut
        if icon.image !== image { icon.image = image }
    }
    func apply(selected: Bool, accent: NSColor, usesMaterial: Bool = true) {
        self.usesMaterial = usesMaterial
        isSelectedResult = selected
        selectionAccent = accent
        refreshBackground()
        let selectedText = usesMaterial && !OrbitAppearance.isDark(effectiveAppearance)
            ? OrbitTokens.Color.Text.commandBarPrimary : OrbitTokens.Color.Text.onAccent
        titleLabel.textColor = selected ? selectedText : OrbitTokens.Color.Text.commandBarPrimary
        detailLabel.textColor = selected ? selectedText.withAlphaComponent(0.72) : OrbitTokens.Color.Text.commandBarSecondary
        actionLabel.textColor = selected ? selectedText : OrbitTokens.Color.Text.commandBarSecondary
        shortcutLabel.textColor = selected ? selectedText.withAlphaComponent(0.8) : OrbitTokens.Color.Text.commandBarSecondary
        let showsAction = showsTabAction || (showsRestoreAction && selected)
        actionIcon.contentTintColor = selected ? accent : OrbitTokens.Color.State.commandBarAccessoryForeground
        actionIcon.isHidden = !showsAction
        accessory.isHidden = !showsAction
        actionLabel.isHidden = !showsAction
        shortcutLabel.isHidden = shortcutLabel.stringValue.isEmpty
        accessory.layer?.backgroundColor = (selected ? NSColor.white : OrbitTokens.Color.State.commandBarAccessory).resolvedCGColor(for: effectiveAppearance)
        let hasWhiteTile = selected && (showsTabAction || !shortcutLabel.stringValue.isEmpty)
        icon.contentTintColor = usesFavicon ? nil : (selected ? (hasWhiteTile ? accent : .white) : OrbitTokens.Color.Text.commandBarPrimary)
        iconTile.layer?.backgroundColor = (hasWhiteTile ? NSColor.white : .clear).resolvedCGColor(for: effectiveAppearance)
        needsLayout = true
    }
    private func refreshBackground() {
        background.layer?.backgroundColor = (isSelectedResult ? (usesMaterial ? OrbitTokens.Color.State.commandBarRowSelected : selectionAccent) :
            (isHovered ? OrbitTokens.Color.State.commandBarRowHover : .clear)).resolvedCGColor(for: effectiveAppearance)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; refreshBackground() }
    override func mouseExited(with event: NSEvent) { isHovered = false; refreshBackground() }
    override func layout() {
        super.layout()
        let m = OrbitTokens.Metrics.CommandBar.self
        background.frame = NSRect(x: 0, y: 0, width: bounds.width, height: m.rowHeight)
        iconTile.frame = NSRect(x: m.iconTileInsetX, y: (m.rowHeight - m.iconTileSize) / 2, width: m.iconTileSize, height: m.iconTileSize)
        let imageSize: CGFloat = 16
        icon.frame = NSRect(x: iconTile.frame.midX - imageSize / 2, y: iconTile.frame.midY - imageSize / 2, width: imageSize, height: imageSize)
        let chipSize = m.accessoryChipSize
        accessory.frame = NSRect(x: max(0, bounds.width - chipSize - m.rowInsetX), y: (m.rowHeight - chipSize) / 2, width: chipSize, height: chipSize)
        actionIcon.frame = accessory.frame.insetBy(dx: 4, dy: 4)
        let x = m.titleOriginX - m.rowInsetX
        func textWidth(_ label: NSTextField) -> CGFloat {
            label.stringValue.isEmpty ? 0 : ceil((label.stringValue as NSString).size(withAttributes: [
                .font: label.font ?? OrbitTokens.Typography.commandBarAccessory
            ]).width) + 4
        }
        let right = !accessory.isHidden ? accessory.frame.minX - 10 : bounds.width - m.rowInsetX
        let shortcutWidth = min(textWidth(shortcutLabel), max(0, (right - x) * 0.25))
        shortcutLabel.frame = NSRect(x: right - shortcutWidth, y: (m.rowHeight - 18) / 2, width: shortcutWidth, height: 18)
        let actionRight = shortcutLabel.frame.minX - (shortcutWidth > 0 ? 14 : 0)
        let actionWidth = !actionLabel.isHidden ? min(textWidth(actionLabel), max(0, (actionRight - x) * 0.33)) : 0
        actionLabel.frame = NSRect(x: actionRight - actionWidth, y: (m.rowHeight - 18) / 2, width: actionWidth, height: 18)
        let usableWidth = max(0, actionLabel.frame.minX - (actionWidth > 0 ? 16 : 0) - x)
        let hasDetail = !detailLabel.stringValue.isEmpty
        let titleWidth = hasDetail ? min(textWidth(titleLabel), usableWidth * 0.62) : usableWidth
        titleLabel.frame = NSRect(x: x, y: (m.rowHeight - 18) / 2, width: titleWidth, height: 18)
        let detailX = titleLabel.frame.maxX + (hasDetail ? 4 : 0)
        detailLabel.frame = NSRect(x: detailX, y: (m.rowHeight - 18) / 2, width: hasDetail ? max(0, x + usableWidth - detailX) : 0, height: 18)
    }
}

/// Decorative backdrop; the palette controls receive all pointer input.
@MainActor
final class OrbitPaletteBackdropView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
