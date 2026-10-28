import AppKit
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct DownloadRowPresentation {
    enum Action { case cancel, pause, resume, open, reveal, remove }
    let id: UUID
    let lifetime: UUID
    let revision: UInt64
    let title: String
    let detail: String
    let receivedBytes: Int64
    let totalBytes: Int64?
    let isRunning: Bool
    let actions: [Action]
    var fileURL: URL? = nil
    var startedAt: Date? = nil
}

/// A profile-scoped native list. Transfer ownership and file effects belong to the coordinator.
@MainActor
final class BrowserDownloadsView: NSView {
    var onDragFile: ((UUID, UUID, UInt64) -> URL?)?
    var onAction: ((UUID, UUID, UInt64, DownloadRowPresentation.Action) -> Void)?
    private(set) var renderCount = 0
    private let rows = NSStackView()
    private let empty = BrowserLibraryEmptyView()
    var emptyQuery = "" { didSet { empty.configure(symbol: BrowserLibraryCategory.downloads.symbol, title: uiText("No Downloads"), query: emptyQuery, largeGlyph: true) } }
    private var rowViews: [UUID: BrowserDownloadRowView] = [:]
    private var headings: [Day: NSTextField] = [:]
    private var presentations: [DownloadRowPresentation] = []
    private var query = ""
    private let dates = BrowserLibraryDateObserver()
    enum Day: Hashable { case dated(Date), undated }

    static func grouped(_ presentations: [DownloadRowPresentation], calendar: Calendar = .current) -> [(Day, [DownloadRowPresentation])] {
        var groups: [Day: [DownloadRowPresentation]] = [:]
        for row in presentations {
            let day = row.startedAt.map { Day.dated(calendar.startOfDay(for: $0)) } ?? .undated
            groups[day, default: []].append(row)
        }
        return groups.keys.sorted {
            switch ($0, $1) {
            case (.dated(let a), .dated(let b)): return a > b
            case (.dated, .undated): return true
            default: return false
            }
        }.map { ($0, (groups[$0] ?? []).sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }) }
    }


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let scroll = NSScrollView()
        BrowserLibraryStyle.configure(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedDownloadDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        addSubview(scroll)
        empty.configure(symbol: BrowserLibraryCategory.downloads.symbol, title: uiText("No Downloads"), largeGlyph: true)
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        dates.onChange = { [weak self] in
            guard let self else { return }; render(presentations, query: query)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); dates.setAttached(window != nil) }

    func render(_ presentations: [DownloadRowPresentation], query: String = "") {
        self.presentations = presentations
        self.query = query
        renderCount += 1
        let live = Set(presentations.map(\.id))
        for id in rowViews.keys.filter({ !live.contains($0) }) {
            rowViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        let visible = presentations.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let groups = Self.grouped(visible)
        let days = Set(groups.map { $0.0 })
        for day in headings.keys.filter({ !days.contains($0) }) { headings.removeValue(forKey: day)?.removeFromSuperview() }
        var arranged: [NSView] = []
        for (day, items) in groups {
            let heading = headings[day] ?? NSTextField(labelWithString: "")
            heading.font = .systemFont(ofSize: 13, weight: .bold)
            heading.textColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.65)
            heading.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
            switch day {
            case .undated: heading.stringValue = uiText("Undated")
            case .dated(let date):
                let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("MMMMd")
                heading.stringValue = Calendar.current.isDateInToday(date) ? uiText("Today")
                    : Calendar.current.isDateInYesterday(date) ? uiText("Yesterday") : formatter.string(from: date)
            }
            if headings[day] == nil { heading.heightAnchor.constraint(equalToConstant: 24).isActive = true }
            headings[day] = heading
            arranged.append(heading)
            for presentation in items {
                let row: BrowserDownloadRowView
                if let existing = rowViews[presentation.id], existing.lifetime == presentation.lifetime {
                    row = existing
                } else {
                    rowViews.removeValue(forKey: presentation.id)?.removeFromSuperview()
                    row = BrowserDownloadRowView(id: presentation.id, lifetime: presentation.lifetime)
                    row.onDragFile = { [weak self] id, lifetime, revision in self?.onDragFile?(id, lifetime, revision) }
                    row.onAction = { [weak self] id, lifetime, revision, action in self?.onAction?(id, lifetime, revision, action) }
                    rowViews[presentation.id] = row

                }
                row.render(presentation)
                arranged.append(row)
            }
        }
        for view in rows.arrangedSubviews where !arranged.contains(where: { $0 === view }) {
            rows.removeArrangedSubview(view); view.removeFromSuperview()
        }
        for (index, view) in arranged.enumerated() {
            if view.superview == nil {
                rows.addArrangedSubview(view)
                if view is BrowserDownloadRowView { view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
            }
            if rows.arrangedSubviews.count <= index || rows.arrangedSubviews[index] !== view {
                if rows.arrangedSubviews.contains(view) { rows.removeArrangedSubview(view) }
                rows.insertArrangedSubview(view, at: index)
            }
        }
        empty.isHidden = !visible.isEmpty
    }

    var displayedTitles: [String] {
        rows.arrangedSubviews.compactMap { ($0 as? BrowserDownloadRowView)?.displayedTitle }
    }
}

@MainActor
private final class FlippedDownloadDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class BrowserDownloadRowView: NSView, NSDraggingSource {
    let id: UUID
    let lifetime: UUID
    var onDragFile: ((UUID, UUID, UInt64) -> URL?)?
    var onAction: ((UUID, UUID, UInt64, DownloadRowPresentation.Action) -> Void)?
    private var revision: UInt64 = 0
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var restingTitleTrailing: NSLayoutConstraint!
    private var activeTitleTrailing: NSLayoutConstraint!
    var areActionsVisible: Bool { !actionStack.isHidden }
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let actionStack = NSStackView()
    let icon = NSImageView()
    private var fileURL: URL?
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private var actionButtons: [(DownloadRowPresentation.Action, NSButton)] = []
    private var shownActions: [DownloadRowPresentation.Action] = []
    var displayedTitle: String { titleLabel.stringValue }

    init(id: UUID, lifetime: UUID) {
        self.id = id
        self.lifetime = lifetime
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        actionStack.orientation = .horizontal
        actionStack.spacing = 2
        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, titleLabel, detailLabel, progress, actionStack] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        }
        restingTitleTrailing = titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        activeTitleTrailing = titleLabel.trailingAnchor.constraint(equalTo: actionStack.leadingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            restingTitleTrailing,
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            progress.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        actionStack.isHidden = true
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    func render(_ row: DownloadRowPresentation) {
        revision = row.revision
        updateIcon(row)
        titleLabel.stringValue = row.title
        detailLabel.stringValue = row.detail
        progress.isHidden = !row.isRunning
        progress.isIndeterminate = row.totalBytes == nil || row.totalBytes == 0
        if let total = row.totalBytes, total > 0 {
            progress.doubleValue = min(1, Double(row.receivedBytes) / Double(total))
            progress.stopAnimation(nil)
        } else if row.isRunning { progress.startAnimation(nil) }
        if shownActions != row.actions {
            for view in actionStack.arrangedSubviews { view.removeFromSuperview() }
            actionButtons.removeAll()
            shownActions = row.actions
            for action in row.actions {
                let pair: (String, String)
                switch action {
                case .cancel: pair = ("xmark", uiText("Cancel"))
                case .pause: pair = ("pause", uiText("Pause"))
                case .resume: pair = ("arrow.clockwise", uiText("Resume"))
                case .open: pair = ("arrow.up.right.square", uiText("Open File"))
                case .reveal: pair = ("magnifyingglass", uiText("Show in Finder"))
                case .remove: pair = ("trash", uiText("Remove from List"))
                }
                let button = NSButton(image: NSImage(systemSymbolName: pair.0, accessibilityDescription: pair.1)!,
                                      target: self, action: #selector(performRowAction(_:)))
                button.isBordered = false
                button.image = button.image?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
                button.widthAnchor.constraint(equalToConstant: 16).isActive = true
                button.heightAnchor.constraint(equalToConstant: 24).isActive = true
                button.toolTip = pair.1
                button.setAccessibilityLabel(pair.1)
                actionStack.addArrangedSubview(button)
                actionButtons.append((action, button))
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { setActionsVisible(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in self?.updateActionsVisibility() }
        }
        return accepted
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated), name: NSWindow.didUpdateNotification, object: window)
        }
        hovered = false
        updateActionsVisibility()
    }
    @objc private func windowUpdated() { updateActionsVisibility() }
    private func updateActionsVisibility() {
        let responder = window?.firstResponder as? NSView
        setActionsVisible(hovered || responder === self || responder?.isDescendant(of: actionStack) == true)
    }
    private func setActionsVisible(_ visible: Bool) {
        guard actionStack.isHidden == visible else { return }
        if visible {
            restingTitleTrailing.isActive = false
            activeTitleTrailing.isActive = true
        } else {
            activeTitleTrailing.isActive = false
            restingTitleTrailing.isActive = true
        }
        actionStack.isHidden = !visible
    }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 36, 76: if shownActions.contains(.open) { onAction?(id, lifetime, revision, .open) }
        case 51, 117: if shownActions.contains(.remove) { onAction?(id, lifetime, revision, .remove) }
        default: super.keyDown(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        for (action, button) in actionButtons {
            let item = NSMenuItem(title: button.toolTip ?? "", action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (revision, action)
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }
    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let (revision, action) = sender.representedObject as? (UInt64, DownloadRowPresentation.Action) else { return }
        onAction?(id, lifetime, revision, action)
    }

    private func updateIcon(_ row: DownloadRowPresentation) {
        guard icon.image == nil || fileURL != row.fileURL else { return }
        if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
        fileURL = row.fileURL
        let type = UTType(filenameExtension: (row.title as NSString).pathExtension) ?? .data
        icon.image = NSWorkspace.shared.icon(for: type)
        guard let url = fileURL else { return }
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 24, height: 24), scale: 2, representationTypes: .thumbnail)
        thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.cgImage
            Task { @MainActor [weak self, image] in
                guard let self, fileURL == url, let image else { return }
                icon.image = NSImage(cgImage: image, size: .zero)
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        titleLabel.textColor = BrowserLibraryStyle.foreground
        detailLabel.textColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.55)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        updateActionsVisibility()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
        updateActionsVisibility()
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), shownActions.contains(.open) else { return }
        onAction?(id, lifetime, revision, .open)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let url = onDragFile?(id, lifetime, revision) else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(origin: point, size: NSSize(width: 32, height: 32)), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    @objc private func performRowAction(_ sender: NSButton) {
        guard let action = actionButtons.first(where: { $0.1 === sender })?.0 else { return }
        onAction?(id, lifetime, revision, action)
    }
}
