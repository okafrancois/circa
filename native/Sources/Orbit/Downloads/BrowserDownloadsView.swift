import AppKit
import Foundation

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
}

/// A profile-scoped native list. Transfer ownership and file effects belong to the coordinator.
@MainActor
final class BrowserDownloadsView: NSView {
    var onDragFile: ((UUID, UUID, UInt64) -> URL?)?
    var onAction: ((UUID, UUID, UInt64, DownloadRowPresentation.Action) -> Void)?
    private(set) var renderCount = 0
    private let rows = NSStackView()
    private let empty = BrowserLibraryEmptyView()
    var emptyQuery = "" { didSet { empty.configure(symbol: BrowserLibraryCategory.downloads.symbol, title: uiText("No Downloads"), query: emptyQuery) } }
    private var rowViews: [UUID: BrowserDownloadRowView] = [:]

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
        empty.configure(symbol: BrowserLibraryCategory.downloads.symbol, title: uiText("No Downloads"))
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func render(_ presentations: [DownloadRowPresentation]) {
        renderCount += 1
        let live = Set(presentations.map(\.id))
        for id in rowViews.keys.filter({ !live.contains($0) }) {
            rowViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, presentation) in presentations.enumerated() {
            let row: BrowserDownloadRowView
            if let existing = rowViews[presentation.id], existing.lifetime == presentation.lifetime {
                row = existing
            } else {
                rowViews.removeValue(forKey: presentation.id)?.removeFromSuperview()
                row = BrowserDownloadRowView(id: presentation.id, lifetime: presentation.lifetime)
                row.onDragFile = { [weak self] id, lifetime, revision in self?.onDragFile?(id, lifetime, revision) }
                row.onAction = { [weak self] id, lifetime, revision, action in self?.onAction?(id, lifetime, revision, action) }
                rowViews[presentation.id] = row
                rows.insertArrangedSubview(row, at: min(index, rows.arrangedSubviews.count))
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            row.render(presentation)
            if rows.arrangedSubviews[index] !== row {
                rows.removeArrangedSubview(row)
                rows.insertArrangedSubview(row, at: index)
            }
        }
        empty.isHidden = !presentations.isEmpty
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
private final class BrowserDownloadRowView: NSView, NSDraggingSource {
    let id: UUID
    let lifetime: UUID
    var onDragFile: ((UUID, UUID, UInt64) -> URL?)?
    var onAction: ((UUID, UUID, UInt64, DownloadRowPresentation.Action) -> Void)?
    private var revision: UInt64 = 0
    private var tracking: NSTrackingArea?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let actionStack = NSStackView()
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
        titleLabel.font = OrbitTokens.Typography.sidebarTabTitle
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = OrbitTokens.Typography.menuShortcut
        detailLabel.textColor = OrbitTokens.Color.Text.secondary
        detailLabel.lineBreakMode = .byTruncatingMiddle
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        let labels = NSStackView(views: [titleLabel, detailLabel, progress])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!)
        icon.contentTintColor = OrbitTokens.Color.Text.secondary
        let line = NSStackView(views: [icon, labels, actionStack])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 12
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 28),
            labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            progress.widthAnchor.constraint(equalTo: labels.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func render(_ row: DownloadRowPresentation) {
        revision = row.revision
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
                button.toolTip = pair.1
                button.setAccessibilityLabel(pair.1)
                actionStack.addArrangedSubview(button)
                actionButtons.append((action, button))
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
    override func mouseDown(with event: NSEvent) { }
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
