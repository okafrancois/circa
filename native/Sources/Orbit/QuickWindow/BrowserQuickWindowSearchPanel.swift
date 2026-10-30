import AppKit
import BrowserShell
import QuartzCore

/// Compact input geometry and 0.083 s linear entry samples.
/// The borderless input is a separate surface; it is not an empty browser window.
enum BrowserQuickWindowMetrics {
    static let inputWidth: CGFloat = 490
    static let inputHeader: CGFloat = 64
    static let inputPitch: CGFloat = 50
    static let inputRadius: CGFloat = 17
    static let rightInset: CGFloat = 20
    static let topInset: CGFloat = 30 // below the visible screen's menu bar
    static let initialPageSize = NSSize(width: 680, height: 360)
    static let inputEntryDuration = 1.0 / 12
    static let inputEntryScales: [Double] = [0.988, 0.994, 1, 1]

    static func frame(size: NSSize, visibleFrame: NSRect) -> NSRect {
        NSRect(x: visibleFrame.maxX - rightInset - size.width,
               y: visibleFrame.maxY - topInset - size.height, width: size.width, height: size.height)
    }
}

@MainActor
struct BrowserQuickWindowSearchRow {
    let id: String
    let title: String
    var detail = ""
    var image: NSImage?
    var iconBackground: NSColor? = nil
    let accept: () -> Void
}

@MainActor
final class BrowserQuickWindowSearchPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    enum Kind { case address, spaces }
    let kind: Kind
    let window: BrowserQuickWindowSearchWindow
    let input = QuickWindowSearchInputField()
    private let placeholder = QuickWindowSearchPlaceholder(labelWithString: "")
    private let root = QuickWindowSearchRoot()
    private let searchIcon = NSImageView()
    private let closeButton = QuickWindowSearchDismissButton()
    private let divider = NSView()
    private let scroll = NSScrollView()
    private let list = QuickWindowSearchRoot()
    private var rowViews: [String: QuickWindowSearchRowButton] = [:]
    private(set) var rows: [BrowserQuickWindowSearchRow] = []
    private(set) var selectedIndex = 0
    var onQuery: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onSubmit: ((String) -> Void)?
    private var ending = false
    private var anchor: NSRect?
    private var editingDocument = false

    init(kind: Kind) {
        self.kind = kind
        window = BrowserQuickWindowSearchWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        super.init()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.animationBehavior = .none
        window.contentView = root
        window.identifier = .init(kind == .address ? "little-orbit-input-panel" : "little-orbit-space-chooser")
        root.wantsLayer = true
        root.layer?.cornerRadius = kind == .address ? BrowserQuickWindowMetrics.inputRadius : 10
        root.layer?.borderWidth = 0.5
        root.onLayout = { [weak self] in self?.layout() }
        root.onAppearance = { [weak self] in self?.applyAppearance() }
        for view in [searchIcon, input, closeButton, divider, scroll] { root.addSubview(view) }
        input.isBordered = false; input.isBezeled = false; input.drawsBackground = false
        input.focusRingType = .none
        input.cell?.usesSingleLineMode = true; input.cell?.isScrollable = true
        input.font = kind == .address ? OrbitTokens.Typography.commandBarInput : BrandTextStyle.ui.font(size: 14, weight: .medium)
        input.placeholderString = kind == .address ? uiText("Search or Enter URL…") : uiText("Search Spaces…")
        input.setAccessibilityLabel(kind == .address ? uiText("Search or Enter URL") : uiText("Search Spaces"))
        input.setAccessibilityIdentifier(kind == .address ? "little-orbit-search" : "little-orbit-space-search")
        input.delegate = self
        input.target = self; input.action = #selector(submit)
        input.cell?.sendsActionOnEndEditing = false
        input.onReturn = { [weak self] in self?.submit() }
        placeholder.stringValue = input.placeholderString ?? ""
        placeholder.font = input.font
        placeholder.setAccessibilityElement(false)
        root.addSubview(placeholder)
        searchIcon.image = OrbitIcon.image(sfName: "magnifyingglass", pointSize: 16, accessibilityDescription: nil)
        searchIcon.setAccessibilityElement(false)
        closeButton.isBordered = false
        closeButton.alwaysHighlighted = kind == .address
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 8
        closeButton.image = OrbitIcon.image(sfName: kind == .address ? "xmark" : "chevron.up", pointSize: 16, accessibilityDescription: nil)
        closeButton.setAccessibilityLabel(kind == .address ? uiText("Close Little Orbit") : uiText("Close"))
        closeButton.target = self; closeButton.action = #selector(cancel)
        divider.wantsLayer = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false; scroll.autohidesScrollers = true
        scroll.documentView = list
        applyAppearance()
    }

    private var header: CGFloat { kind == .address ? 64 : 46 }
    private var pitch: CGFloat { kind == .address ? 50 : 46 }
    private var width: CGFloat { kind == .address ? (editingDocument ? 500 : 490) : 244 }
    var preferredSize: NSSize {
        let listHeight = CGFloat(min(rows.count, 7)) * pitch
        return NSSize(width: width, height: kind == .address ? header + (rows.isEmpty ? 0 : 6) + listHeight + 8 : header + listHeight)
    }

    private func applyAppearance() {
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = root.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            root.layer?.backgroundColor = NSColor.clear.cgColor
            OrbitFloatingMaterial.install(in: root, blending: .behindWindow, radius: BrowserQuickWindowMetrics.inputRadius)
            divider.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            closeButton.layer?.backgroundColor = (kind == .address ? (dark ? NSColor.labelColor.withAlphaComponent(0.07) : OrbitTokens.Color.State.commandBarAccessory) : NSColor.clear).cgColor
        }
        input.textColor = OrbitFloatingMaterial.body
        searchIcon.contentTintColor = kind == .address ? .labelColor : .secondaryLabelColor
        closeButton.contentTintColor = .secondaryLabelColor
        input.placeholderAttributedString = NSAttributedString(string: input.placeholderString ?? "", attributes: [
            .font: input.font!, .foregroundColor: placeholder.textColor ?? NSColor.secondaryLabelColor])
        let dark = root.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        placeholder.textColor = OrbitFloatingMaterial.secondary
        for view in rowViews.values { view.needsDisplay = true }
    }

    func setEditingDocument(_ editing: Bool) {
        editingDocument = editing
        searchIcon.image = OrbitIcon.image(sfName: editing ? "globe" : "magnifyingglass", pointSize: 16, accessibilityDescription: nil)
        closeButton.setAccessibilityLabel(editing ? uiText("Close") : uiText("Close Little Orbit"))
    }

    func showCentered(over parent: NSWindow) {
        let size = preferredSize
        let frame = NSRect(x: parent.frame.midX - size.width / 2,
                           y: parent.frame.midY - size.height / 2 + 20, width: size.width, height: size.height)
        show(anchor: NSRect(x: frame.maxX - 3, y: frame.maxY - 4.5, width: 0, height: 0), screen: parent.screen)
        input.selectText(nil)
    }

    func show(anchor: NSRect? = nil, screen: NSScreen? = nil) {
        ending = false
        self.anchor = anchor
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 958)
        let frame = anchor.map { NSRect(x: $0.maxX + 3 - width, y: $0.maxY + 4.5 - preferredSize.height, width: width, height: preferredSize.height) }
            ?? BrowserQuickWindowMetrics.frame(size: preferredSize, visibleFrame: visible)
        window.setFrame(frame, display: false)
        root.layoutSubtreeIfNeeded()
        applyAppearance()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
        (input.currentEditor() as? NSTextView)?.drawsBackground = false
        root.addSubview(placeholder, positioned: .above, relativeTo: nil)
        placeholder.isHidden = !input.stringValue.isEmpty
        if kind == .address, !editingDocument, !OrbitMotionPreferences.prefersReducedMotion, let layer = root.layer {
            layer.anchorPoint = NSPoint(x: 0.5, y: 0.5)
            layer.position = NSPoint(x: root.bounds.midX, y: root.bounds.midY)
            let entry = CAKeyframeAnimation(keyPath: "transform.scale")
            entry.values = BrowserQuickWindowMetrics.inputEntryScales
            entry.keyTimes = [0, 0.4, 0.8, 1]
            entry.duration = BrowserQuickWindowMetrics.inputEntryDuration
            entry.calculationMode = .linear
            layer.add(entry, forKey: "little.input.entry")
        }
    }

    func hide() { ending = true; window.orderOut(nil) }
    func close() { ending = true; window.close() }
    func windowDidResignKey(_ notification: Notification) { if !ending { onCancel?() } }
    @objc private func cancel() { onCancel?() }
    func controlTextDidChange(_ notification: Notification) {
        placeholder.isHidden = !input.stringValue.isEmpty
        onQuery?(input.stringValue)
    }
    @objc private func submit() {
        if rows.indices.contains(selectedIndex) { rows[selectedIndex].accept() }
        else { onSubmit?(input.stringValue) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) { move(1); return true }
        if selector == #selector(NSResponder.moveUp(_:)) { move(-1); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            guard !textView.hasMarkedText() else { return false }
            submit()
            return true
        }
        return false
    }
    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = selectedIndex < 0 ? (delta < 0 ? rows.count - 1 : 0) : (selectedIndex + delta + rows.count) % rows.count
        refreshSelection()
    }
    func render(_ rows: [BrowserQuickWindowSearchRow], preserveSelection: Bool = true) {
        let selectedID = preserveSelection && self.rows.indices.contains(selectedIndex) ? self.rows[selectedIndex].id : nil
        self.rows = rows
        selectedIndex = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? (kind == .spaces && input.stringValue.isEmpty ? -1 : 0)
        let ids = Set(rows.map(\.id))
        for id in Array(rowViews.keys) where !ids.contains(id) { rowViews.removeValue(forKey: id)?.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            let view = rowViews[row.id] ?? QuickWindowSearchRowButton()
            rowViews[row.id] = view
            view.row = row; view.kind = kind; view.editingDocument = editingDocument
            view.onHover = { [weak self] in self?.selectedIndex = index; self?.refreshSelection() }
            if view.superview == nil { list.addSubview(view) }
        }
        if window.isVisible {
            var frame = window.frame
            frame.origin.y = frame.maxY - preferredSize.height
            frame.size = preferredSize
            window.setFrame(frame, display: true)
        }
        root.needsLayout = true; root.layoutSubtreeIfNeeded()
        refreshSelection()
    }
    private func refreshSelection() {
        for (index, row) in rows.enumerated() { rowViews[row.id]?.selected = index == selectedIndex }
    }
    private func layout() {
        let bounds = root.bounds
        placeholder.isHidden = !input.stringValue.isEmpty
        let leading: CGFloat = kind == .address ? 52 : 46
        input.frame = NSRect(x: leading - 2, y: header / 2 - 13, width: max(0, bounds.width - leading - 55), height: 30)
        placeholder.frame = NSRect(x: leading - 2, y: header / 2 - (kind == .address ? 13 : 10),
                                   width: max(0, bounds.width - leading - 55), height: 30)
        searchIcon.frame = NSRect(x: kind == .address ? 24 : 14, y: header / 2 - 7, width: 14, height: 14)
        closeButton.frame = NSRect(x: bounds.width - (kind == .address ? 46 : 36), y: header / 2 - 12, width: 24, height: 24)
        divider.frame = kind == .address
            ? NSRect(x: 12, y: header - 0.5, width: max(0, bounds.width - 24), height: 0.5)
            : NSRect(x: bounds.width - 39, y: header / 2 - 11, width: 0.5, height: 22)
        divider.isHidden = rows.isEmpty && kind == .address
        scroll.frame = kind == .address
            ? NSRect(x: 10, y: header + 6, width: max(0, bounds.width - 20), height: max(0, bounds.height - header - 14))
            : NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        list.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: CGFloat(rows.count) * pitch)
        for (index, row) in rows.enumerated() { rowViews[row.id]?.frame = NSRect(x: 0, y: CGFloat(index) * pitch, width: list.bounds.width, height: kind == .address ? pitch - 4 : pitch) }
    }
}

@MainActor
final class BrowserQuickWindowSearchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class QuickWindowSearchRoot: NSView {
    var onLayout: (() -> Void)?
    var onAppearance: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearance?() }
}

@MainActor
private final class QuickWindowSearchRowButton: NSButton {
    var row: BrowserQuickWindowSearchRow? { didSet { title = row?.title ?? ""; setAccessibilityLabel(row?.title); needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    var kind = BrowserQuickWindowSearchPanel.Kind.address
    var editingDocument = false
    var onHover: (() -> Void)?
    private var tracking: NSTrackingArea?
    init() { super.init(frame: .zero); title = ""; isBordered = false; target = self; action = #selector(accept) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    @objc private func accept() { row?.accept() }
    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let isAddress = kind == .address
        if selected {
            let selection = NSColor.controlAccentColor.withAlphaComponent(0.12)
            selection.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: isAddress ? 8 : 0, yRadius: isAddress ? 8 : 0).fill()
        }
        if !isAddress, let fill = row.iconBackground {
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: 10, y: (bounds.height - 26) / 2, width: 26, height: 26), xRadius: 5, yRadius: 5).fill()
        }
        let iconSize: CGFloat = isAddress ? 20 : 16
        let textX: CGFloat = isAddress ? 42 : 46
        let color = OrbitFloatingMaterial.body
        OrbitIcon.draw(row.image, in: NSRect(x: isAddress ? 12 : 15, y: (bounds.height - iconSize) / 2,
                                             width: iconSize, height: iconSize), tint: color)
        let font = BrandTextStyle.ui.font(size: 13, weight: .medium)
        let title = NSAttributedString(string: row.title, attributes: [.font: font, .foregroundColor: color])
        let titleWidth = min(title.size().width, max(0, bounds.width - 66))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (row.title as NSString).draw(in: NSRect(x: textX, y: (bounds.height - 17) / 2, width: titleWidth, height: 17),
                                    withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        (row.detail as NSString).draw(in: NSRect(x: 50 + titleWidth, y: (bounds.height - 16) / 2,
                                               width: max(0, bounds.width - titleWidth - 60), height: 16),
                                     withAttributes: [.font: BrandTextStyle.ui.font(size: 12), .foregroundColor: OrbitFloatingMaterial.secondary, .paragraphStyle: paragraph])
    }
}

@MainActor
final class QuickWindowSearchInputField: NSTextField {
    var onReturn: (() -> Void)?
    private func acceptReturn(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, [36, 76].contains(event.keyCode),
              (currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
        onReturn?()
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if currentEditor() != nil, acceptReturn(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) { if !acceptReturn(event) { super.keyDown(with: event) } }
}

@MainActor
private final class QuickWindowSearchPlaceholder: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class QuickWindowSearchDismissButton: NSButton {
    var alwaysHighlighted = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor }
    override func mouseExited(with event: NSEvent) { if !alwaysHighlighted { layer?.backgroundColor = NSColor.clear.cgColor } }
}
