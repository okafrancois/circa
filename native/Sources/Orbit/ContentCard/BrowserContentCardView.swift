import AppKit
import QuartzCore

@MainActor
final class BrowserContentCardView: NSView {
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
    private var edgeConstraints: [(NSLayoutConstraint, CGFloat)] = []
    private var contentTopConstraint: NSLayoutConstraint?
    private weak var headerView: NSView?
    private var headerConstraints: [NSLayoutConstraint] = []
    var headerHeight: CGFloat { headerView == nil ? 0 : BrowserDeveloperToolbar.height }
    var pageViewportSize: NSSize {
        NSSize(width: clip.bounds.width, height: max(0, clip.bounds.height - headerHeight))
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
    var themeForeground: NSColor? { didSet { hairline.borderColor = themeForeground?.withAlphaComponent(0.12) ?? OrbitTokens.Color.Line.floatingScrimBorder } }
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
        for view in [clip, hairline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            let edges = [
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ]
            edgeConstraints += zip(edges, [CGFloat(1), -1, 1, -1]).map { ($0.0, $0.1) }
            NSLayoutConstraint.activate(edges)
        }
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
            NSLayoutConstraint.activate([
                presentation.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                presentation.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
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
