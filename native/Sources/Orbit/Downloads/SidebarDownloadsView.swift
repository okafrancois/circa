import AppKit
import BrowserCore
import BrowserShell
import QuartzCore

enum SidebarDownloadListMetrics {
    static let rowHeight: CGFloat = 56
    static let thumbnailSize: CGFloat = 40
    static let veilFadeHeight: CGFloat = 160
    static let veilClearance: CGFloat = 8
}

@MainActor
final class SidebarDownloadsView: SidebarHoverPopoverSurface {
    var onVeilChange: (() -> Void)?
    var onAction: ((BrowserDownloadContext) -> Void)?
    var accent = OrbitTokens.ThemeAccent.defaultSpace { didSet { refreshRows() } }
    private(set) var items: [BrowserDownloadSnapshot] = []
    private let icons = BrowserDownloadIconCache(capacity: 16, thumbnailSize: SidebarDownloadListMetrics.thumbnailSize)
    private var rows: [SidebarRecentDownloadRow] = []
    private(set) var isPresented = false
    private var generation = UUID()
    private var ageTimer: (any OrbitCancellable)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; isHidden = true }
    required init?(coder: NSCoder) { nil }

    func render(_ items: [BrowserDownloadSnapshot], presented: Bool) {
        self.items = items
        while rows.count > items.count { rows.removeLast().removeFromSuperview() }
        while rows.count < items.count {
            let row = SidebarRecentDownloadRow(icons: icons)
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
        for (row, item) in zip(rows, items) { row.render(item, ink: ink, loadThumbnail: isPresented) }
    }
    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(index) * SidebarDownloadListMetrics.rowHeight, width: bounds.width, height: SidebarDownloadListMetrics.rowHeight) }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { ageTimer?.cancel(); ageTimer = nil } }

    private func scheduleAgeRefresh() {
        ageTimer = OrbitRunLoopTimer(after: 1) { [weak self] in
            guard let self, isPresented else { return }
            refreshRows(); scheduleAgeRefresh()
        }
    }

    private func setPresented(_ value: Bool) {
        guard value != isPresented else { return }
        isPresented = value; generation = UUID(); let token = generation
        ageTimer?.cancel(); ageTimer = nil
        if value { refreshRows(); scheduleAgeRefresh() }
        guard let layer else {
            isHidden = !value
            onVeilChange?()
            return
        }
        layer.removeAllAnimations()
        isHidden = false
        onVeilChange?()
        layoutSubtreeIfNeeded()
        let animated = window?.isVisible == true && !OrbitMotionPreferences.prefersReducedMotion
        let duration = SidebarDownloadMotion.sampleTimes.last!
        let times = SidebarDownloadMotion.sampleTimes.map { NSNumber(value: $0 / duration) }
        let stagger = value ? SidebarDownloadMotion.stagger : SidebarDownloadMotion.exitStagger
        for (index, row) in rows.enumerated() {
            row.displayIfNeeded()
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
                guard let self, generation == token else { return }
                isHidden = true
                onVeilChange?()
            }
        }

    }
}

@MainActor
private final class SidebarRecentDownloadRow: NSButton {
    private static let titleFont = OrbitTokens.Typography.sidebarTabTitle
    private static let ageFont = BrandTextStyle.ui.font(size: 12)
    private static let textStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private var icon: NSImage?
    private var filename = ""
    private var age = ""
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var ink = OrbitTokens.ThemeAccent.defaultSpace
    private let icons: BrowserDownloadIconCache
    private var iconExtension: String?
    private var thumbnailURL: URL?
    private var thumbnailRequest: BrowserDownloadIconCache.Request?
    private(set) var item: BrowserDownloadSnapshot?
    var onActivate: (() -> Void)?
    override var isFlipped: Bool { true }
    init(icons: BrowserDownloadIconCache) {
        self.icons = icons
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(activate)
    }
    required init?(coder: NSCoder) { nil }
    func render(_ item: BrowserDownloadSnapshot, ink: OrbitTokens.ThemeAccent, loadThumbnail: Bool) {
        self.item = item; self.ink = ink
        filename = DownloadRowPresentation.title(item)
        let fileExtension = (filename as NSString).pathExtension
        let url = item.state == .complete && item.fileAvailability == .available ? item.destinationURL : nil
        if fileExtension != iconExtension || url != thumbnailURL {
            thumbnailRequest?.cancel()
            thumbnailRequest = nil
            thumbnailURL = url
            iconExtension = fileExtension
            icon = icons.typeIcon(forExtension: fileExtension)
        }
        if loadThumbnail, let url, thumbnailRequest == nil {
            let cached = icons.cached(url)
            if let image = cached?.image { icon = image }
            if cached?.isComplete != true {
                thumbnailRequest = icons.load(url, fileIcon: false, thumbnail: true) { [weak self] image in
                    self?.icon = image
                    self?.thumbnailRequest = nil
                    self?.needsDisplay = true
                }
            }
        }
        if item.state == .failed || item.state == .cancelled || item.state == .paused || item.state == .interrupted {
            age = DownloadRowPresentation(item).detail
        } else if let date = item.startedAt {
            let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .full
            age = formatter.localizedString(for: date, relativeTo: Date())
        } else { age = DownloadRowPresentation(item).detail }
        setAccessibilityLabel(uiFormat("%@, %@", filename, age))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            ink.sidebarText.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        // Draw the row as one backing store so its entry animation carries the thumbnail and
        // both labels together, even when it initially starts below the visible list.
        let size = SidebarDownloadListMetrics.thumbnailSize
        if let icon, icon.size.width > 0, icon.size.height > 0 {
            let rect = NSRect(x: 8, y: (bounds.height - size) / 2, width: size, height: size)
            let scale = min(size / icon.size.width, size / icon.size.height)
            let width = icon.size.width * scale
            let height = icon.size.height * scale
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            icon.draw(in: NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let textWidth = max(0, bounds.width - 84)
        guard textWidth > 0 else { return }
        (filename as NSString).draw(with: NSRect(x: 60, y: 13, width: textWidth, height: 19),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: Self.titleFont, .foregroundColor: ink.sidebarText, .paragraphStyle: Self.textStyle], context: nil)
        (age as NSString).draw(with: NSRect(x: 60, y: 30, width: textWidth, height: 16),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: Self.ageFont, .foregroundColor: ink.sidebarText.withAlphaComponent(0.6), .paragraphStyle: Self.textStyle], context: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            thumbnailRequest?.cancel()
            thumbnailRequest = nil
            hovering = false
        }
    }
    @objc private func activate() { onActivate?() }
}

/// The hit-transparent sibling follows the footer layout and can include a badge that extends
/// above the footer's bounds. Clicks still go to the original Library button or download row.
@MainActor
final class SidebarDownloadHoverTarget: NSView {
    var onEnter: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard let window, SidebarHoverPopover.visibleRect(of: self, in: window)?.contains(event.locationInWindow) == true else { return }
        guard permitsPopoverHover(event), (window as? OrbitBrowserWindow)?.isRestoringPopoverHover != true else { return }
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {}
}
