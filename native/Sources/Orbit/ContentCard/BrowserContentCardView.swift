import AppKit
import QuartzCore

@MainActor
final class BrowserContentCardView: NSView {
    private var assistant: NSView?
    private let assistantClip = NSView()
    private var assistantContentWidth: CGFloat = 0
    private let assistantGrip = BrowserAssistantResizeGrip()
    private var assistantWidth: CGFloat = 0
    private var pageTrailing: NSLayoutConstraint?
    private var clipTrailing: NSLayoutConstraint?
    private var assistantAnimation: Task<Void, Never>?
    /// The dock's sibling card: Space fill aligned to the window, opaque tint, same edge and shadow as the page.
    private let assistantSurface = OrbitThemeFillView()
    private let assistantTint = NSView()
    private let assistantEdge = OrbitSurfaceBackgroundView(cornerRadius: OrbitTokens.Radius.contentCard)
    func setAssistant(_ view: NSView?, width: CGFloat) {
        assistantAnimation?.cancel()
        let target = view == nil ? 0 : min(480, max(300, width))
        if let view {
            assistant?.removeFromSuperview()
            assistant = view
            assistantContentWidth = target
            assistantClip.wantsLayer = true
            assistantClip.layer?.masksToBounds = true
            assistantClip.layer?.cornerRadius = 6
            installAssistantSurface()
            assistantClip.addSubview(view)
            assistantGrip.removeFromSuperview()
            addSubview(assistantGrip)
            assistantGrip.onDrag = { [weak self] delta in
                guard let self else { return }
                resizeAssistant(by: delta)
            }
        }
        let initial = assistantWidth
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        let duration = reduced ? 0.15 : view == nil ? 0.24 : 0.38
        updateAssistantLayout()
        assistant?.layoutSubtreeIfNeeded()
        assistantAnimation = Task { [weak self] in
            // Initial hosting layout must finish before the first animation interval begins.
            let start = CACurrentMediaTime()
            while let self, !Task.isCancelled {
                let fraction = min(1, (CACurrentMediaTime() - start) / duration)
                if reduced {
                    assistantWidth = view == nil ? initial : target
                    assistant?.alphaValue = view == nil ? 1 - fraction : fraction
                } else {
                    assistantWidth = initial + (target - initial) * BrowserAssistantMotion.progress(fraction, opening: view != nil)
                }
                updateAssistantLayout()
                if fraction >= 1 {
                    assistantWidth = target
                    if view == nil {
                        assistant?.removeFromSuperview(); assistant = nil
                        assistantClip.removeFromSuperview(); assistantGrip.removeFromSuperview()
                        assistantEdge.removeFromSuperview()
                    }
                    assistant?.alphaValue = 1
                    updateAssistantLayout()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
    private func installAssistantSurface() {
        guard assistantClip.superview == nil else { return }
        assistantEdge.borderWidth = OrbitTokens.Metrics.Content.cardHairlineWidth
        assistantEdge.outerShadow = OrbitTokens.Shadow.contentCard
        assistantEdge.borderColor = themeForeground?.withAlphaComponent(0.12) ?? OrbitTokens.Color.Line.floatingScrimBorder
        addSubview(assistantClip)
        addSubview(assistantEdge)
        assistantClip.addSubview(assistantSurface)
        assistantTint.wantsLayer = true
        assistantClip.addSubview(assistantTint)
    }
    /// Grain and glass stay in the shell and stop at both edges of the dock.
    func setAssistantSurface(theme: OrbitTokens.SpaceTheme, tint: NSColor) {
        // Painting can precede attaching the assistant host on its first reveal.
        installAssistantSurface()
        var fill = theme
        fill.texture = .none
        fill.textureIntensity = 0
        assistantSurface.applyInteractiveTheme(fill)
        assistantTint.layer?.backgroundColor = tint.cgColor
    }
    func resizeAssistant(by delta: CGFloat) {
        guard assistant != nil else { return }
        assistantAnimation?.cancel()
        assistantWidth = min(480, max(300, assistantWidth - delta))
        assistantContentWidth = assistantWidth
        updateAssistantLayout()
    }
    private func updateAssistantLayout() {
        clipTrailing?.constant = assistantWidth == 0 ? 0 : -(assistantWidth + 10)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    /// The dock's palette follows the window appearance even though its own view is pinned to Space polarity.
    var onEffectiveAppearanceChange: (() -> Void)?
    private let clip = BrowserContentCardClipView()
    private let hairline = OrbitSurfaceBackgroundView(cornerRadius: OrbitTokens.Radius.contentCard)
    private let emptyTitle = NSTextField(labelWithString: OrbitShellText.emptySpaceTitle)
    private let emptyDetail = NSTextField(labelWithString: OrbitShellText.emptySpaceDetail)
    private let emptyState = NSStackView()
    private weak var presentedView: NSView?
    private let captureShield = NSView()
    private let splitBackdrop = OrbitThemeFillView()
    private var retentionTokens: [ObjectIdentifier: UUID] = [:]
    private var paintHeldView: NSView?
    private var paintHoldToken: UUID?
    private var returningToHeldPage = false
    private var isPresentingSplit = false
    private var contentTopConstraint: NSLayoutConstraint?
    private weak var headerView: NSView?
    private var headerConstraints: [NSLayoutConstraint] = []
    var headerHeight: CGFloat { headerView == nil ? 0 : BrowserDeveloperToolbar.height }
    var pageViewportSize: NSSize {
        NSSize(width: max(0, clip.bounds.width), height: max(0, clip.bounds.height - headerHeight))
    }
    func setHeader(_ view: NSView?) {
        guard headerView !== view else { return }
        NSLayoutConstraint.deactivate(headerConstraints)
        headerView?.removeFromSuperview()
        headerView = view
        headerConstraints = []
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(view, positioned: .above, relativeTo: nil)
            headerConstraints = [view.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                view.topAnchor.constraint(equalTo: clip.topAnchor), view.heightAnchor.constraint(equalToConstant: BrowserDeveloperToolbar.height)]
            NSLayoutConstraint.activate(headerConstraints)
        }
        contentTopConstraint?.constant = headerHeight
    }
    var peekRecede: CGFloat = 0 {
        didSet { layer?.transform = peekTransform }
    }

    private var peekTransform: CATransform3D {
        let sx = max(0, 1 - 2 * peekRecede / max(1, bounds.width))
        let sy = max(0, 1 - 2 * peekRecede / max(1, bounds.height))
        let anchor = layer?.anchorPoint ?? .zero
        let dx = (0.5 - anchor.x) * bounds.width, dy = (0.5 - anchor.y) * bounds.height
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), sx, sy, 1), -dx, -dy, 0)
    }

    func setPeekDimmed(_ dimmed: Bool, animated: Bool) {
        let target = dimmed ? BrowserPeekMotion.backgroundInset : 0
        guard peekRecede != target else { return }
        let oldTransform = layer?.presentation()?.transform ?? layer?.transform ?? CATransform3DIdentity
        let oldOpacity = layer?.presentation()?.opacity ?? Float(alphaValue)
        layer?.removeAnimation(forKey: "peek.background.transform")
        layer?.removeAnimation(forKey: "peek.background.opacity")
        peekRecede = target
        alphaValue = dimmed ? BrowserPeekMotion.backgroundOpacity : 1
        guard animated, !OrbitMotionPreferences.prefersReducedMotion, let layer else { return }
        let spring = dimmed ? BrowserPeekMotion.dim : BrowserPeekMotion.undim
        let transform = spring.animation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: oldTransform)
        transform.toValue = NSValue(caTransform3D: peekTransform)
        layer.add(transform, forKey: "peek.background.transform")
        let opacity = spring.animation(keyPath: "opacity")
        opacity.fromValue = oldOpacity
        opacity.toValue = Float(alphaValue)
        layer.add(opacity, forKey: "peek.background.opacity")
    }
    var frameEdgeColor: NSColor? { hairline.borderColor }
    var themeForeground: NSColor? {
        didSet {
            hairline.borderColor = themeForeground?.withAlphaComponent(0.12) ?? OrbitTokens.Color.Line.floatingScrimBorder
            assistantEdge.borderColor = hairline.borderColor
        }
    }
    var splitTheme: OrbitTokens.SpaceTheme = .default {
        didSet { splitBackdrop.apply(splitTheme) }
    }
    /// Tests can fire the timeout deterministically without depending on main-actor load.
    var scheduleCaptureRetirement: @MainActor (@escaping @MainActor () -> Void) -> Void = { retire in
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(500)); retire() }
    }
    var schedulePaintRetirement: @MainActor (@escaping @MainActor () -> Void) -> Void = { retire in
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(150)); retire() }
    }
    func isPresenting(_ view: NSView) -> Bool { presentedView === view }

    var cornerRadius: CGFloat = OrbitTokens.Radius.contentCard {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        clip.translatesAutoresizingMaskIntoConstraints = false
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        addSubview(hairline)
        clipTrailing = clip.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: leadingAnchor), clipTrailing!,
            clip.topAnchor.constraint(equalTo: topAnchor), clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: clip.topAnchor),
            hairline.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
        ])
        hairline.borderColor = OrbitTokens.Color.Line.floatingScrimBorder
        hairline.borderWidth = OrbitTokens.Metrics.Content.cardHairlineWidth
        hairline.outerShadow = OrbitTokens.Shadow.contentCard
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 4
        emptyTitle.font = OrbitTokens.Typography.emptyStateTitle
        emptyTitle.textColor = OrbitTokens.Color.Text.secondary
        emptyTitle.lineBreakMode = .byTruncatingTail
        emptyDetail.font = OrbitTokens.Typography.emptyStateDetail
        emptyDetail.textColor = OrbitTokens.Color.Text.tertiary
        emptyState.addArrangedSubview(emptyTitle)
        emptyState.addArrangedSubview(emptyDetail)
        splitBackdrop.autoresizingMask = [.width, .height]
        captureShield.addSubview(splitBackdrop)
    }

    required init?(coder: NSCoder) { nil }

    /// The card is page content, never a window-drag area (unlike the Space fill around it).
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func layout() {
        super.layout()
        assistantGrip.frame = NSRect(x: bounds.width - assistantWidth - 10, y: 0, width: 10, height: bounds.height)
        assistantClip.frame = NSRect(x: bounds.width - assistantWidth, y: 0, width: assistantWidth, height: bounds.height)
        assistantEdge.frame = assistantClip.frame
        // The clip reveals a stationary dock: no text reflow, and its fill stays aligned with the window's.
        let dock = NSRect(x: assistantWidth - assistantContentWidth, y: 0, width: assistantContentWidth, height: bounds.height)
        assistant?.frame = dock
        assistantSurface.frame = dock
        assistantTint.frame = dock
        if assistant != nil, let root = window?.contentView {
            let rect = convert(NSRect(x: bounds.width - assistantContentWidth, y: 0, width: assistantContentWidth, height: bounds.height), to: root)
            assistantSurface.windowFillSize = root.bounds.size
            assistantSurface.offsetInWindowFill = CGPoint(x: rect.minX, y: root.isFlipped ? rect.minY : root.bounds.height - rect.maxY)
        }
        if peekRecede != 0 { layer?.transform = peekTransform }
        clip.layer?.cornerRadius = cornerRadius
        hairline.cornerRadius = cornerRadius
        splitBackdrop.frame = captureShield.bounds
        if let root = window?.contentView {
            let rect = convert(bounds, to: root)
            splitBackdrop.windowFillSize = root.bounds.size
            splitBackdrop.offsetInWindowFill = CGPoint(x: rect.minX,
                y: root.isFlipped ? rect.minY : root.bounds.height - rect.maxY)
        }
    }

    /// The card's shadow (tests): cast by the hairline view, masked to the outside of the shape.
    var shadowSpec: OrbitTokens.ShadowSpec? { hairline.outerShadow }
    /// Background of the clip: the empty-page overlay or the page backdrop.
    var clipBackground: CGColor? { clip.layer?.backgroundColor }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The hairline view owns the shadow (THEME-R2); only the capture shield needs re-resolving.
        refreshCaptureShield()
        onEffectiveAppearanceChange?()
    }

    var emptyStateTitle: String {
        get { emptyTitle.stringValue }
        set { emptyTitle.stringValue = newValue }
    }
    var emptyStateDetail: String {
        get { emptyDetail.stringValue }
        set { emptyDetail.stringValue = newValue }
    }

    /// The empty-state title while it is displayed, nil while a page is presented.
    var displayedEmptyTitle: String? { presentedView === emptyState ? emptyTitle.stringValue : nil }

    /// Presents an engine host view edge to edge, or the empty state for nil.
    /// Presenting the view already displayed does nothing, so the document is never reloaded.
    func present(_ view: NSView?, isSplit: Bool = false, retainingPreviousUntil capture: Task<Void, Never>? = nil,
                 holdingPreviousUntil paint: Task<Bool, Never>? = nil) {
        let mayHold = !isPresentingSplit && !isSplit && view != nil && !returningToHeldPage
        returningToHeldPage = false
        isPresentingSplit = isSplit
        clip.isTransparent = isSplit
        clip.layer?.masksToBounds = !isSplit
        hairline.isHidden = isSplit
        let presentation: NSView = view ?? emptyState
        guard presentedView !== presentation else { return }
        let previous = presentedView
        if paint == nil || !mayHold || paintHeldView === presentation { retirePaintHold() }
        if paint != nil, mayHold, paintHeldView == nil, previous !== emptyState {
            paintHeldView = previous
        }
        presentedView = presentation
        retentionTokens[ObjectIdentifier(presentation)] = nil
        if let previous, let capture {
            let key = ObjectIdentifier(previous)
            let token = UUID()
            retentionTokens[key] = token
            // Keep the outgoing document attached behind its replacement while its engine paints
            // the snapshot. Neither reparent the new page nor wait to show it.
            let retire: @MainActor () -> Void = { [weak self, weak previous] in
                guard let self, self.retentionTokens[key] == token else { return }
                self.retentionTokens[key] = nil
                guard let previous, self.presentedView !== previous, self.paintHeldView !== previous,
                      previous.superview === self.clip else { return }
                previous.removeFromSuperview()
            }
            Task { await capture.value; retire() }
            scheduleCaptureRetirement(retire)
        } else if let previous {
            retentionTokens[ObjectIdentifier(previous)] = nil
            if paintHeldView !== previous { previous.removeFromSuperview() }
        }
        // Retained outgoing documents must never show through a transparent/new host view.
        captureShield.wantsLayer = true
        refreshCaptureShield()
        captureShield.frame = clip.bounds
        captureShield.autoresizingMask = [.width, .height]
        clip.addSubview(captureShield, positioned: .above, relativeTo: nil)
        clip.showsEmptyPage = view == nil
        presentation.translatesAutoresizingMaskIntoConstraints = false
        let wasAttached = presentation.superview === clip
        clip.addSubview(presentation, positioned: .above, relativeTo: nil)
        if let held = paintHeldView, let paint, held !== presentation, held.superview === clip {
            // Keep the last displayed native pixels above the incoming host, without moving
            // either host through an off-window parent or adding a fade.
            clip.addSubview(held, positioned: .above, relativeTo: presentation)
            let token = UUID()
            paintHoldToken = token
            let retire: @MainActor () -> Void = { [weak self] in
                guard let self, self.paintHoldToken == token else { return }
                self.retirePaintHold()
            }
            Task { if await paint.value { retire() } }
            schedulePaintRetirement(retire)
        }
        if let headerView { clip.addSubview(headerView, positioned: .above, relativeTo: nil) }
        if wasAttached { return }
        if view != nil {
            let top = presentation.topAnchor.constraint(equalTo: clip.topAnchor, constant: headerHeight)
            contentTopConstraint = top
            pageTrailing = presentation.trailingAnchor.constraint(equalTo: clip.trailingAnchor)
            NSLayoutConstraint.activate([
                presentation.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                pageTrailing!,
                top,
                presentation.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
            ])
        } else {
            contentTopConstraint = nil
            NSLayoutConstraint.activate([
                presentation.centerXAnchor.constraint(equalTo: clip.centerXAnchor),
                presentation.centerYAnchor.constraint(equalTo: clip.centerYAnchor),
                presentation.widthAnchor.constraint(lessThanOrEqualTo: clip.widthAnchor, constant: -40)
            ])
        }
    }

    /// A document returning before its outgoing capture finished has one native parent only.
    /// Its pending snapshot was invalidated by the switcher before this call; retire the old
    /// wrapper and invalidate its receipt before moving the host into a new presentation.
    func prepareToReparent(_ host: NSView) {
        for previous in clip.subviews where previous !== presentedView && previous !== captureShield {
            guard host === previous || host.isDescendant(of: previous) else { continue }
            if paintHeldView === previous {
                returningToHeldPage = true
                retirePaintHold()
            }
            retentionTokens[ObjectIdentifier(previous)] = nil
            previous.removeFromSuperview()
        }
    }

    private func retirePaintHold() {
        let held = paintHeldView
        paintHeldView = nil
        paintHoldToken = nil
        guard let held, held !== presentedView, held.superview === clip else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if retentionTokens[ObjectIdentifier(held)] != nil {
            clip.addSubview(held, positioned: .below, relativeTo: captureShield)
        } else { held.removeFromSuperview() }
        CATransaction.commit()
    }

    private func refreshCaptureShield() {
        splitBackdrop.isHidden = !isPresentingSplit
        captureShield.layer?.backgroundColor = isPresentingSplit ? NSColor.clear.cgColor
            : (presentedView === emptyState ? OrbitTokens.Color.Surface.contentEmptyPage : OrbitTokens.Color.Surface.preview)
                .resolvedCGColor(for: effectiveAppearance)
    }
}

@MainActor
private final class BrowserContentCardClipView: NSView {
    var isTransparent = false { didSet { refresh() } }
    var showsEmptyPage = true { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let colour = showsEmptyPage ? OrbitTokens.Color.Surface.contentEmptyPage : OrbitTokens.Color.Surface.preview
        layer?.backgroundColor = isTransparent ? NSColor.clear.cgColor : colour.resolvedCGColor(for: effectiveAppearance)
    }
}

@MainActor
private final class BrowserAssistantResizeGrip: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var previousX: CGFloat?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { previousX = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        if let previousX { onDrag?(x - previousX) }
        previousX = x
    }
    override func mouseUp(with event: NSEvent) { previousX = nil }
}
