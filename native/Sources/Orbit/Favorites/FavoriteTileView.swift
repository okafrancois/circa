import AppKit
import BrowserCore

enum FavoritesPresentationTokens {
    static let unloadedIconOpacity: CGFloat = 1
    static let placeholderFontSize: CGFloat = 18
    static let dragThreshold: CGFloat = 4
}

struct FavoriteTileItem: Equatable {
    let tab: BrowserOrganizationTabItem
    var favicon: NSImage?
    var isLoading = false
    var isAudible: Bool?
    var isAudioMuted: Bool?

    var title: String { tab.title ?? tab.pinnedURL?.host ?? tab.url.host ?? uiText("Favorite") }
    var placeholder: String {
        // A page title can be the application's New Tab title. Use the site's home identity,
        // never the application's N monogram, when no site icon has been published.
        let name = tab.pinnedURL?.host ?? tab.url.host ?? ""
        let trimmed = name.hasPrefix("www.") ? String(name.dropFirst(4)) : name
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }
}

/// An icon-only button. The grid retains it by TabID so updates preserve pointer state.
@MainActor
final class FavoriteTileView: NSView {
    private(set) var item: FavoriteTileItem
    let background = OrbitSurfaceBackgroundView(cornerRadius: OrbitTokens.Radius.favoriteTile)
    private let favicon = FavoriteFaviconImageView()
    private let letter = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var pressPoint: NSPoint?
    private var selectionTint: NSColor?
    private(set) var isHovering = false
    private(set) var isPressed = false
    var commandsEnabled = true { didSet { if !commandsEnabled { cancelPress() } } }
    var onSelect: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var makeContextMenu: (() -> NSMenu?)?

    init(item: FavoriteTileItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        favicon.imageScaling = .scaleProportionallyDown
        letter.font = .systemFont(ofSize: FavoritesPresentationTokens.placeholderFontSize, weight: .semibold)
        letter.alignment = .center
        letter.textColor = OrbitTokens.Color.Text.primary
        letter.wantsLayer = true
        letter.layer?.cornerRadius = 4
        letter.layer?.masksToBounds = true
        // Orbit's favorite tiles carry no corner glyphs (audio, loading, "away from pinned URL");
        // those states stay in the accessibility value and the context menu (user, 28/10).
        for view in [background, favicon, letter] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(item)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func update(_ item: FavoriteTileItem) {
        if self.item.favicon !== item.favicon || favicon.image == nil {
            let presentation = item.favicon.flatMap(Self.iconPresentation)
            selectionTint = presentation?.tint
            favicon.image = presentation?.image
            favicon.contentTintColor = presentation?.image.isTemplate == true ? OrbitTokens.Color.Text.primary : nil
        }
        self.item = item
        favicon.isHidden = item.favicon == nil
        letter.stringValue = item.placeholder
        letter.layer?.backgroundColor = OrbitTokens.Color.Text.secondary.withAlphaComponent(0.18).cgColor
        letter.isHidden = item.favicon != nil
        let alpha: CGFloat = item.tab.isLoadedInThisWindow ? 1 : FavoritesPresentationTokens.unloadedIconOpacity
        favicon.alphaValue = alpha
        letter.alphaValue = alpha
        setAccessibilityLabel(item.title)
        var states: [String] = []
        if item.tab.isSelected { states.append(uiText("Selected")) }
        if item.isLoading { states.append(uiText("Loading")) }
        if item.tab.isAwayFromPinnedURL { states.append(uiText("Address Changed")) }
        if item.isAudioMuted == true { states.append(uiText("Muted")) }
        else if item.isAudible == true { states.append(uiText("Playing Audio")) }
        if !item.tab.isLoadedInThisWindow { states.append(uiText("Not Loaded")) }
        setAccessibilityValue(states.joined(separator: ", "))
        setAccessibilityHelp(item.tab.isAwayFromPinnedURL ? uiText("Use the menu to reset the favorite to its original URL.") : nil)
        toolTip = item.title
        refreshFill()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let size = OrbitTokens.Metrics.Sidebar.favoriteIconSize
        let icon = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        favicon.frame = icon
        let height = max(size, ceil(letter.intrinsicContentSize.height))
        letter.frame = NSRect(x: (bounds.width - height) / 2, y: (bounds.height - height) / 2, width: height, height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        if let tracking { addTrackingArea(tracking) }
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; refreshFill() }
    override func mouseExited(with event: NSEvent) { isHovering = false; refreshFill() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard commandsEnabled, let superview, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovering = false; cancelPress() }
    }
    override func mouseDown(with event: NSEvent) {
        guard commandsEnabled else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        pressPoint = event.locationInWindow
        isPressed = true
        refreshFill()
    }
    override func mouseDragged(with event: NSEvent) {
        guard commandsEnabled, let start = pressPoint else { return }
        guard hypot(start.x - event.locationInWindow.x, start.y - event.locationInWindow.y)
                >= FavoritesPresentationTokens.dragThreshold else { return }
        cancelPress()
        onDrag?(event)
    }
    override func mouseUp(with event: NSEvent) {
        let select = isPressed && commandsEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
        cancelPress()
        if select { onSelect?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        cancelPress()
        guard commandsEnabled, let menu = makeContextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func accessibilityPerformPress() -> Bool {
        guard commandsEnabled else { return false }
        onSelect?()
        return true
    }
    func cancelPress() { pressPoint = nil; isPressed = false; refreshFill() }

    private func refreshFill() {
        let state = OrbitTokens.Color.State.self
        background.fillColor = isPressed ? state.tabPressed : item.tab.isSelected ? state.tabCurrent
            : isHovering ? state.sidebarItemHovered : state.sidebarItem
        background.outerShadow = item.tab.isSelected && !isPressed ? OrbitTokens.Shadow.tabSelected : nil
        background.borderWidth = item.tab.isSelected && selectionTint != nil ? OrbitTokens.Metrics.Sidebar.favoriteSelectedRingWidth : 0
        background.borderColor = item.tab.isSelected ? selectionTint : nil
        if item.tab.isSelected, !isPressed, let selectionTint {
            let darkFill = selectionTint.withAlphaComponent(isHovering ? 0.32 : 0.24)
            background.fillColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkFill : state.tabCurrent.resolved(for: appearance)
            }
        }
    }

    private static func iconPresentation(_ image: NSImage) -> (image: NSImage, tint: NSColor)? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, weight: CGFloat = 0
        var transparent = 0, visible = 0, monochrome = 0
        for x in 0..<16 { for y in 0..<16 {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.alphaComponent < 0.1 { transparent += 1 }
            if color.alphaComponent > 0.5 {
                visible += 1
                let maximum = max(color.redComponent, color.greenComponent, color.blueComponent)
                let minimum = min(color.redComponent, color.greenComponent, color.blueComponent)
                if maximum < 0.28 && maximum - minimum < 0.12 { monochrome += 1 }
            }
            let contribution = color.alphaComponent * color.saturationComponent * color.saturationComponent
            red += color.redComponent * contribution; green += color.greenComponent * contribution
            blue += color.blueComponent * contribution; weight += contribution
        } }
        // Transparent black marks (e.g. GitHub's fallback favicon) must remain visible on a
        // dark tile. Two-tone icons with an opaque white backing retain their original pixels.
        let rendered: NSImage
        if transparent > 32, visible > 0, monochrome * 100 / visible > 95,
           let template = image.copy() as? NSImage {
            template.isTemplate = true
            rendered = template
        } else { rendered = image }
        guard weight > 1 else { return (rendered, OrbitTokens.Color.Text.secondary) }
        let color = NSColor(srgbRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
        return (rendered, NSColor(srgbRed: color.redComponent * 0.65 + 0.35, green: color.greenComponent * 0.65 + 0.35,
                                 blue: color.blueComponent * 0.65 + 0.35, alpha: 1))
    }
}

/// Paint the alpha mask explicitly so decoded public monochrome artwork follows the Space appearance.
@MainActor
final class FavoriteFaviconImageView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.isTemplate, let context = NSGraphicsContext.current?.cgContext else {
            super.draw(dirtyRect)
            return
        }
        let scale = min(1, min(bounds.width / max(1, image.size.width), bounds.height / max(1, image.size.height)))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        context.saveGState()
        context.beginTransparencyLayer(in: target, auxiliaryInfo: nil)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        OrbitTokens.Color.Text.primary.resolved(for: effectiveAppearance).setFill()
        target.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
