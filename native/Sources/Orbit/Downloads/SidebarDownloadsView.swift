import AppKit
import BrowserCore
import BrowserShell
import QuartzCore
import UniformTypeIdentifiers

@MainActor
final class SidebarDownloadsView: NSView {
    var onHover: ((Bool) -> Void)?
    var onAction: ((BrowserDownloadContext) -> Void)?
    var accent = OrbitTokens.ThemeAccent.defaultSpace { didSet { refreshRows() } }
    private(set) var items: [BrowserDownloadSnapshot] = []
    private var rows: [SidebarRecentDownloadRow] = []
    private var tracking: NSTrackingArea?
    private var presented = false
    private var generation = UUID()
    private var ageTimer: (any OrbitCancellable)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; isHidden = true }
    required init?(coder: NSCoder) { nil }

    func render(_ items: [BrowserDownloadSnapshot], presented: Bool) {
        self.items = items
        while rows.count > items.count { rows.removeLast().removeFromSuperview() }
        while rows.count < items.count {
            let row = SidebarRecentDownloadRow()
            row.onActivate = { [weak self, weak row] in
                guard let self, let row, let context = row.item?.context else { return }
                onAction?(context)
            }
            addSubview(row); rows.append(row)
        }
        refreshRows()
        needsLayout = true
        setPresented(presented)
    }
    private func refreshRows() {
        let ink = OrbitFloatingMaterial.sidebarInk(accent)
        for (row, item) in zip(rows, items) { row.render(item, ink: ink) }
    }
    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(index) * 56, width: bounds.width, height: 56) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { ageTimer?.cancel(); ageTimer = nil } }

    private func scheduleAgeRefresh() {
        ageTimer = OrbitRunLoopTimer(after: 1) { [weak self] in
            guard let self, presented else { return }
            refreshRows(); scheduleAgeRefresh()
        }
    }

    private func setPresented(_ value: Bool) {
        guard value != presented else { return }
        presented = value; generation = UUID(); let token = generation
        ageTimer?.cancel(); ageTimer = nil
        if value { scheduleAgeRefresh() }
        guard let layer else { isHidden = !value; return }
        layer.removeAllAnimations()
        isHidden = false
        layoutSubtreeIfNeeded()
        let animated = window?.isVisible == true && !OrbitMotionPreferences.prefersReducedMotion
        let duration = SidebarDownloadMotion.sampleTimes.last!
        let times = SidebarDownloadMotion.sampleTimes.map { NSNumber(value: $0 / duration) }
        let stagger = value ? SidebarDownloadMotion.stagger : SidebarDownloadMotion.exitStagger
        for (index, row) in rows.enumerated() {
            row.wantsLayer = true
            guard let rowLayer = row.layer else { continue }
            let opacity = rowLayer.presentation()?.opacity ?? rowLayer.opacity
            let transform = rowLayer.presentation()?.transform ?? rowLayer.transform
            rowLayer.removeAllAnimations()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rowLayer.opacity = value ? 1 : 0
            rowLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            guard animated else { continue }
            let delay = Double(rows.count - 1 - index) * stagger
            let movement = CAKeyframeAnimation(keyPath: "transform")
            movement.keyTimes = times
            movement.values = (value ? SidebarDownloadMotion.entryOffsets : SidebarDownloadMotion.exitOffsets).enumerated().map { sample, offset in
                NSValue(caTransform3D: sample == 0 && !value ? transform : CATransform3DMakeTranslation(0, offset, 0))
            }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.keyTimes = times
            fade.values = value ? SidebarDownloadMotion.entryOpacity : SidebarDownloadMotion.exitOpacity.enumerated().map { sample, amount in sample == 0 ? Double(opacity) : amount }
            for animation in [movement, fade] {
                animation.duration = duration
                animation.beginTime = rowLayer.convertTime(CACurrentMediaTime(), from: nil) + delay
                animation.fillMode = .backwards
            }
            rowLayer.add(movement, forKey: "downloads.position")
            rowLayer.add(fade, forKey: "downloads.opacity")
        }
        if !value {
            let total = animated ? duration + Double(max(0, rows.count - 1)) * stagger : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in
                guard let self, generation == token else { return }; isHidden = true
            }
        }

    }
}

@MainActor
private final class SidebarRecentDownloadRow: NSButton {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var ink = OrbitTokens.ThemeAccent.defaultSpace
    private var iconName: String?
    private(set) var item: BrowserDownloadSnapshot?
    var onActivate: (() -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); title = ""; isBordered = false
        setButtonType(.momentaryPushIn); target = self; action = #selector(activate)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = OrbitTokens.Typography.sidebarTabTitle
        age.font = BrandTextStyle.ui.font(size: 11)
        name.lineBreakMode = .byTruncatingMiddle
        for view in [icon, name, age] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    func render(_ item: BrowserDownloadSnapshot, ink: OrbitTokens.ThemeAccent) {
        self.item = item; self.ink = ink
        let filename = DownloadRowPresentation.title(item)
        name.stringValue = filename
        if filename != iconName {
            iconName = filename
            icon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data)
        }
        if item.state == .failed || item.state == .cancelled || item.state == .paused || item.state == .interrupted {
            age.stringValue = DownloadRowPresentation(item).detail
        } else if let date = item.startedAt {
            let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .full
            age.stringValue = formatter.localizedString(for: date, relativeTo: Date())
        } else { age.stringValue = DownloadRowPresentation(item).detail }
        name.textColor = ink.sidebarText; age.textColor = ink.sidebarText.withAlphaComponent(0.6)
        setAccessibilityLabel(uiFormat("%@, %@", filename, age.stringValue))
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: 8, width: 40, height: 40)
        name.frame = NSRect(x: 60, y: 10, width: max(0, bounds.width - 68), height: 19)
        age.frame = NSRect(x: 60, y: 29, width: max(0, bounds.width - 68), height: 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            ink.sidebarText.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    @objc private func activate() { onActivate?() }
}
