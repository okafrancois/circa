import AppKit
import BrowserCore
import BrowserShell

enum GmailPreviewMetrics {
    static let width: CGFloat = 250
    static let maximumHeight: CGFloat = 300
    static let rowHeight: CGFloat = 84
    static let cornerRadius: CGFloat = 12
}

/// Plain native text only. Remote markup and message links never become rendered HTML.
@MainActor
final class GmailPreviewView: NSView {
    let scroll = NSScrollView()
    private let document = SidebarFlippedView()
    private let empty = NSTextField(wrappingLabelWithString: uiText("No unread emails, you can exhale!"))
    private let compose = NSButton(title: "", target: nil, action: nil)
    private var rows: [GmailPreviewRow] = []
    private var tracking: NSTrackingArea?
    private var inbox: BrowserGmailInbox?
    var onPointer: ((Bool) -> Void)?
    var onMessage: ((String) -> Void)?
    var onCompose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = GmailPreviewMetrics.cornerRadius
        layer?.masksToBounds = true
        let material = NSVisualEffectView(frame: bounds)
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.autoresizingMask = [.width, .height]
        addSubview(material)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        document.addSubview(empty)
        compose.bezelStyle = .circular
        compose.isBordered = true
        compose.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        compose.imagePosition = .imageOnly
        compose.target = self
        compose.action = #selector(composeMessage)
        compose.toolTip = uiText("Compose")
        compose.setAccessibilityLabel(uiText("Compose"))
        addSubview(compose)
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("Gmail preview"))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var contentHeight: CGFloat {
        guard let inbox else { return 84 }
        return min(GmailPreviewMetrics.maximumHeight, max(84, CGFloat(inbox.messages.count) * GmailPreviewMetrics.rowHeight))
    }

    func render(_ inbox: BrowserGmailInbox) {
        guard self.inbox != inbox else { return }
        let position = scroll.contentView.bounds.origin
        self.inbox = inbox
        for row in rows { row.removeFromSuperview() }
        rows = inbox.messages.map { message in
            let row = GmailPreviewRow(message: message)
            row.onChoose = { [weak self] in self?.onMessage?(message.id) }
            document.addSubview(row)
            return row
        }
        empty.isHidden = !inbox.messages.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .init(x: 0, y: min(position.y, max(0, document.frame.height - scroll.contentSize.height))))
    }

    func clear() {
        inbox = nil
        for row in rows { row.removeFromSuperview() }
        rows.removeAll()
        empty.isHidden = true
        scroll.contentView.scroll(to: .zero)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        document.frame.size = .init(width: scroll.contentSize.width,
            height: max(bounds.height, CGFloat(rows.count) * GmailPreviewMetrics.rowHeight))
        for (index, row) in rows.enumerated() {
            row.frame = .init(x: 0, y: CGFloat(index) * GmailPreviewMetrics.rowHeight,
                              width: document.bounds.width, height: GmailPreviewMetrics.rowHeight)
        }
        empty.frame = .init(x: 20, y: 20, width: max(0, bounds.width - 40), height: 42)
        compose.frame = .init(x: bounds.width - 40, y: bounds.height - 40, width: 32, height: 32)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
    }
    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }
    @objc private func composeMessage() { onCompose?() }
}

@MainActor
private final class GmailPreviewRow: NSView {
    private let sender = NSTextField(labelWithString: "")
    private let subject = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let date = NSTextField(labelWithString: "")
    var onChoose: (() -> Void)?
    private var pressed = false
    init(message: BrowserGmailMessage) {
        super.init(frame: .zero)
        sender.stringValue = message.sender
        sender.font = .systemFont(ofSize: 13, weight: .semibold)
        subject.stringValue = message.subject
        subject.font = .systemFont(ofSize: 13)
        summary.stringValue = message.summary
        summary.font = .systemFont(ofSize: 11)
        summary.maximumNumberOfLines = 2
        summary.textColor = .secondaryLabelColor
        date.font = .systemFont(ofSize: 11)
        date.textColor = .tertiaryLabelColor
        date.alignment = .right
        if let received = message.receivedAt {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
            formatter.maximumUnitCount = 1
            date.stringValue = formatter.string(from: max(60, Date().timeIntervalSince(received))) ?? ""
        }
        for field in [sender, subject, summary, date] { field.lineBreakMode = .byTruncatingTail; addSubview(field) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([message.sender, message.subject, message.summary].joined(separator: ", "))
        setAccessibilityChildren([])
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func layout() {
        super.layout()
        let dateWidth = min(64, date.intrinsicContentSize.width)
        date.frame = .init(x: bounds.width - dateWidth - 12, y: 10, width: dateWidth, height: 16)
        sender.frame = .init(x: 12, y: 10, width: max(0, date.frame.minX - 18), height: 16)
        subject.frame = .init(x: 12, y: 27, width: max(0, bounds.width - 24), height: 16)
        summary.frame = .init(x: 12, y: 44, width: max(0, bounds.width - 24), height: 28)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5).fill()
    }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let choose = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if choose { onChoose?() }
    }
    override func accessibilityPerformPress() -> Bool { onChoose?(); return true }
}
