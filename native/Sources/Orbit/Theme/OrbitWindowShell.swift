import AppKit
import OSLog

/// Feature object of the Themes & motion lot, owned by each browser window controller: the Space
/// fill, the window frame and its buttons, the sidebar column (pinned / hidden / hover-revealed),
/// the content card's insets and corners, the resize edge and full-screen behaviour.
/// It is not generic over the engine: it only places the sidebar view and the card view it is
/// given, and reports presentation changes through closures.
@MainActor
final class OrbitWindowShell {
    let themeFill = OrbitThemeFillView(materialRole: .windowShell)
    let floatingBackdrop = OrbitFloatingSidebarBackdrop()
    let resizeHandle = OrbitSidebarResizeHandle()
    let loadingIndicator = OrbitLoadingIndicatorView()
    let hoverReveal = OrbitSidebarHoverReveal()
    private(set) lazy var hoverTracker = OrbitSidebarHoverTracker(reveal: hoverReveal)

    private(set) var dockProgress: Double = 1
    private(set) var floatProgress: Double = 0
    private var usesFloatingFrame = false
    private var sidebarTransition: UUID?
    private var retainsOffscreenChrome = false
    private static let signposter = OSSignposter(subsystem: "local.orbit", category: "sidebar-motion")
    private let themeMotion = OrbitSpringAnimator(value: 1, usesCoreVideoClock: true)
    private var themeMotionSource: OrbitTokens.SpaceTheme?
    private weak var window: NSWindow?
    private weak var root: OrbitWindowRootView?
    private weak var card: BrowserContentCardView?
    private weak var libraryOutgoingSidebar: NSView?
    private var trafficLights: OrbitTrafficLights?
    private var width: NSLayoutConstraint?
    private var sidebarLeading: NSLayoutConstraint?
    private var sidebarTop: NSLayoutConstraint?
    private var sidebarBottom: NSLayoutConstraint?
    private var dockLeading: NSLayoutConstraint?
    private var cardGap: NSLayoutConstraint?
    private var cardTop: NSLayoutConstraint?
    private var cardTrailing: NSLayoutConstraint?
    private var cardBottom: NSLayoutConstraint?
    private let dockGuide = NSLayoutGuide()
    private let observers = OrbitNotificationObservers()
    private let releaseMonitor = OrbitSidebarReleaseMonitor()
    private var menuTrackingDepth = 0
    private var isApplying = false
    private var libraryVisibleWidth: CGFloat = 0
    var libraryPreservesDocumentWidth = false {
        didSet { if oldValue != libraryPreservesDocumentWidth { applyGeometry() } }
    }
    private var libraryProgress: CGFloat = 0

    func setLibraryProgress(_ value: CGFloat) {
        guard libraryProgress != value else { return }
        libraryProgress = value
        applyGeometry()
    }

    /// Reserve the Library's visible column without changing the user's sidebar width or dock state.
    func setLibraryVisibleWidth(_ value: CGFloat) {
        guard abs(libraryVisibleWidth - value) > 0.01 else { return }
        libraryVisibleWidth = value
        applyGeometry()
    }

    /// Layout uses the full-screen insets from `willEnterFullScreen` to `willExitFullScreen`.
    private(set) var isFullScreen = false
    /// The system owns the window buttons from `willEnterFullScreen` to `didExitFullScreen`.
    private var systemOwnsWindowButtons = false
    private(set) var isDocked = true
    private(set) var geometry: OrbitShellGeometry?
    private(set) var theme: OrbitTokens.SpaceTheme = .default
    private(set) var spaceSwipeBlend: SpaceSwipeThemeBlend?
    /// Width chosen by the user's resize; the downloads column temporarily overrides the constraint.
    private(set) var preferredSidebarWidth = OrbitTokens.Metrics.Sidebar.widthDefault

    var allowsHoverReveal: () -> Bool = { true }
    var allowsResize: () -> Bool = { true }
    /// Editing inside the sidebar keeps a revealed sidebar open.
    var isHoverHeld: () -> Bool = { false }
    var onPresentationChange: (() -> Void)?
    var onSidebarWidthChange: (() -> Void)?
    var onCollapseRequest: (() -> Void)?
    var onFullScreenChange: ((Bool) -> Void)?
    /// Centre spacing of this window's system buttons.
    var trafficLightPitch: CGFloat { trafficLights?.pitch ?? OrbitTrafficLights.pitch }

    var isSidebarOnScreen: Bool { isAnimating || (geometry?.isSidebarOnScreen ?? isDocked) }
    var isFloatingRevealed: Bool { !isDocked && floatProgress > 0 }
    var isAnimating: Bool { sidebarTransition != nil }

    /// Native input is injectable so hidden tests do not inherit the user's physical mouse state.
    init(isMouseButtonPressed: @escaping () -> Bool = { NSEvent.pressedMouseButtons != 0 }) {
        hoverReveal.onRevealChange = { [weak self] reveal in self?.setFloating(reveal) }
        hoverReveal.isHeld = { [weak self] in
            guard let self else { return false }
            // Only feature-owned presentations hold the sidebar. AppKit also attaches persistent
            // fullscreen chrome as a visible child window; child visibility is not a popover signal.
            return menuTrackingDepth > 0 || isHoverHeld() || isMouseButtonPressed()
        }
        hoverReveal.isPointerInside = { [weak self] in self?.hoverTracker.isPointerInsideKeepRegion() ?? false }
    }

    // MARK: Installation

    /// Configures the window frame and puts the Space fill at the bottom of `root`.
    func prepare(window: NSWindow, root: OrbitWindowRootView) {
        self.window = window
        self.root = root
        OrbitWindowChrome.configure(window)
        trafficLights = OrbitTrafficLights(window: window)
        window.appearance = OrbitAppearance.windowAppearance(for: theme.mode)
        root.wantsLayer = true
        themeFill.frame = root.bounds
        themeFill.autoresizingMask = [.width, .height]
        root.addSubview(themeFill, positioned: .below, relativeTo: nil)
        root.onLayout = { [weak self] in self?.applyGeometry() }
        root.onTrackingAreasInvalidated = { [weak self] in self?.updateHoverRegions(force: true) }
        themeFill.onMaterialChange = { [weak self] in self?.updateWindowBackground() }
        themeFill.onAppearanceChange = { [weak self] in self?.updateWindowBackground() }
        observeWindow(window)
        installReleaseMonitor()
        updateWindowBackground()
    }

    /// Recheck after AppKit has delivered the release and ended any field editing. The event is
    /// never consumed, and scroll/swipe routing remains owned by the sidebar.
    private func installReleaseMonitor() {
        releaseMonitor.token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window {
                    DispatchQueue.main.async { [weak self] in self?.hoverHoldDidChange() }
                }
            }
            return event
        }
    }

    /// Adds the floating panel; call between the card overlays and the sidebar so it sits under the
    /// sidebar and over the page.
    func installFloatingBackdrop(in root: NSView) {
        floatingBackdrop.isHidden = true
        root.addSubview(floatingBackdrop)
    }

    /// Adds the loading capsule of the top margin; call right after adding the card.
    func installLoadingIndicator(in root: NSView) {
        root.addSubview(loadingIndicator)
    }

    func setLoadingPhase(_ phase: OrbitLoadingIndicatorView.Phase) {
        loadingIndicator.setPhase(phase, animated: canAnimate)
    }

    /// Adds the resize edge; call last so it is above the sidebar column.
    func installResizeHandle(in root: NSView) {
        resizeHandle.setAccessibilityElement(false)
        root.addSubview(resizeHandle)
        resizeHandle.currentWidth = { [weak self] in self?.width?.constant ?? OrbitTokens.Metrics.Sidebar.widthDefault }
        resizeHandle.onResize = { [weak self] value in self?.setSidebarWidth(value) }
        resizeHandle.onCollapse = { [weak self] in self?.onCollapseRequest?() }
    }

    /// Lays out the sidebar column and the card. `width` and `leading` stay owned by the
    /// controller (other features read and set the column width).
    func installConstraints(root: NSView, sidebar: NSView, card: BrowserContentCardView,
                            width: NSLayoutConstraint, leading: NSLayoutConstraint) {
        self.card = card
        libraryOutgoingSidebar = sidebar
        self.width = width
        sidebarLeading = leading
        root.addLayoutGuide(dockGuide)
        let sidebarTop = sidebar.topAnchor.constraint(equalTo: root.topAnchor)
        let sidebarBottom = root.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        let dockLeading = dockGuide.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        let cardGap = card.leadingAnchor.constraint(equalTo: dockGuide.trailingAnchor)
        let inset = OrbitTokens.Metrics.Content.cardInset
        let cardTop = card.topAnchor.constraint(equalTo: root.topAnchor, constant: inset)
        let cardTrailing = root.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: inset)
        let cardBottom = root.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: inset)
        NSLayoutConstraint.activate([
            width, leading, sidebarTop, sidebarBottom,
            dockGuide.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            dockGuide.topAnchor.constraint(equalTo: root.topAnchor),
            dockGuide.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dockLeading, cardGap, cardTop, cardTrailing, cardBottom
        ])
        self.sidebarTop = sidebarTop
        self.sidebarBottom = sidebarBottom
        self.dockLeading = dockLeading
        self.cardGap = cardGap
        self.cardTop = cardTop
        self.cardTrailing = cardTrailing
        self.cardBottom = cardBottom
        applyGeometry()
    }

    // MARK: Sidebar presentation

    /// ⌘S semantics: pinned sidebar or hidden sidebar with hover reveal. Docking from the floating
    /// panel morphs it into the column. Orbit uses an 80 ms finite cubic (WindowLayoutController).
    /// `animated: false` is the instant drag-to-hide path.
    func setDocked(_ docked: Bool, animated: Bool = true) {
        guard docked != isDocked else { return }
        animateSidebar(animated: animated) {
            self.isDocked = docked
            self.dockProgress = docked ? 1 : 0
            self.floatProgress = 0
            self.usesFloatingFrame = false
            self.hoverReveal.setEnabled(false)
        }
    }

    /// Orbit animates the floating container's frame once with a native CASpringAnimation.
    func setFloating(_ revealed: Bool, animated: Bool = true) {
        guard !isDocked else { return }
        if revealed, !allowsHoverReveal() {
            hoverReveal.dismiss()
            return
        }
        guard floatProgress != (revealed ? 1 : 0) else { return updateHoverRegions() }
        if !usesFloatingFrame {
            // Prepare the offscreen container without resizing the page or animating its bounds.
            usesFloatingFrame = true
            applyGeometry()
            root?.layoutSubtreeIfNeeded()
        }
        animateSidebar(animated: animated, spring: OrbitTokens.Motion.sidebarHoverReveal) {
            self.floatProgress = revealed ? 1 : 0
        }
        updateHoverRegions()
    }

    /// Re-evaluates the hold of a revealed sidebar (editing ended, focus moved).
    func hoverHoldDidChange() { hoverReveal.holdDidChange() }

    /// Column width from the resize edge; the downloads column bypasses this.
    func setSidebarWidth(_ value: CGFloat) {
        guard allowsResize(), let width else { return }
        let changed = preferredSidebarWidth != value
        preferredSidebarWidth = value
        if width.constant != value { width.constant = value }
        applyGeometry()
        if changed { onSidebarWidthChange?() }
    }

    /// Returns the column to the user's width after a temporary override (downloads).
    func restorePreferredSidebarWidth() {
        guard let width else { return }
        if width.constant != preferredSidebarWidth { width.constant = preferredSidebarWidth }
        applyGeometry()
    }

    private func sidebarSettled() {
        // Commit the floating container's offscreen geometry before the pointer can arm it.
        // The first hover then has the same already-sized backing layers as later hovers.
        let prepareFloating = !isDocked && floatProgress == 0 && !usesFloatingFrame
        if prepareFloating { usesFloatingFrame = true }
        // A floating transition can finish while the leave timer is armed. Do not cancel it.
        if isDocked { hoverReveal.setEnabled(false) }
        else if hoverReveal.phase == .disabled { hoverReveal.setEnabled(allowsHoverReveal()) }
        updateHoverRegions()
        applyGeometry()
        if prepareFloating {
            root?.layoutSubtreeIfNeeded()
            root?.displayIfNeeded()
        }
        onPresentationChange?()
    }

    /// / : final frames and one layout inside
    /// NSAnimationContext. Core Animation interpolates; no display-link constraint/CEF resizing.
    private var sidebarAnimationRoots: [CALayer?] {
        [libraryOutgoingSidebar?.layer, card?.layer, floatingBackdrop.layer, loadingIndicator.layer,
         systemOwnsWindowButtons ? nil : trafficLights?.animationLayer]
    }

    private func animateSidebar(animated: Bool, spring: OrbitTokens.Spring? = nil, updates: () -> Void) {
        let style = OrbitMotionStyle.resolve(animated: animated, canAnimate: canAnimate,
                                           reducedMotion: OrbitMotionPreferences.prefersReducedMotion)
        guard style == .spring, let root else {
            sidebarTransition = nil
            OrbitSidebarLayerTransition(roots: sidebarAnimationRoots).cancel()
            if style == .crossfade { OrbitTransitions.crossfade(self.root?.layer) }
            updates()
            applyGeometry()
            self.root?.layoutSubtreeIfNeeded()
            sidebarSettled()
            return
        }
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let token = UUID()
        retainsOffscreenChrome = true
        sidebarTransition = token
        let interval = Self.signposter.beginInterval("SidebarTransition", id: Self.signposter.makeSignpostID())
        onPresentationChange?()
        // Hidden/offscreen AppKit views may be absent from their parent's backing sublayers.
        // Capture each container directly, including the first floating reveal after hiding.
        let layers = OrbitSidebarLayerTransition(roots: sidebarAnimationRoots)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                Self.signposter.endInterval("SidebarTransition", interval)
                guard let self, self.sidebarTransition == token else { return }
                self.sidebarTransition = nil
                self.sidebarSettled()
            }
        }
        updates()
        applyGeometry()
        let layout = Self.signposter.beginInterval("SidebarLayout", id: Self.signposter.makeSignpostID())
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        Self.signposter.endInterval("SidebarLayout", layout)
        let count = layers.animate(spring: spring)
        Self.signposter.emitEvent("SidebarLayerAnimations", "count \(count)")
        CATransaction.commit()
    }

    private var canAnimate: Bool {
        guard let window, window.isVisible, !window.inLiveResize else { return false }
        return window.occlusionState.contains(.visible)
    }

    // MARK: Geometry

    func applyGeometry() {
        guard !isApplying, let root, let width, let sidebarLeading, let card else { return }
        let interval = Self.signposter.beginInterval("SidebarGeometry", id: Self.signposter.makeSignpostID())
        isApplying = true
        defer {
            isApplying = false
            Self.signposter.endInterval("SidebarGeometry", interval)
        }
        let size = root.bounds.size
        var resolved = OrbitShellGeometry.resolve(.init(
            contentSize: size, sidebarWidth: width.constant, dockProgress: CGFloat(dockProgress),
            floatProgress: CGFloat(floatProgress), usesFloatingFrame: usesFloatingFrame, isFullScreen: isFullScreen, trafficLightPitch: trafficLightPitch))
        if libraryVisibleWidth > 0 {
            // WindowLayoutController interpolates the document edge between sidebarPage
            // and home. It moves throughout the transition, including while Home is offscreen.
            let displacement = max(0, libraryVisibleWidth - resolved.cardFrame.minX * libraryProgress)
            resolved.cardFrame.origin.x += displacement
            // A wide destination pushes the document beyond the window instead of
            // shrinking its native controls or increasing the window's fitting width.
            if !libraryPreservesDocumentWidth { resolved.cardFrame.size.width -= displacement }
            resolved.cardGap += displacement
        }
        let wasOnScreen = geometry?.isSidebarOnScreen
        geometry = resolved
        set(sidebarLeading, resolved.sidebarFrame.minX)
        set(sidebarTop, resolved.sidebarFrame.minY)
        set(sidebarBottom, size.height - resolved.sidebarFrame.maxY)
        set(dockLeading, resolved.dockedColumnMinX)
        set(cardGap, resolved.cardGap)
        set(cardTop, resolved.cardFrame.minY)
        set(cardTrailing, size.width - resolved.cardFrame.maxX)
        set(cardBottom, size.height - resolved.cardFrame.maxY)
        card.cornerRadius = resolved.cardRadius
        loadingIndicator.place(over: resolved.cardFrame, in: size)

        let chrome = resolved.floatingChrome
        floatingBackdrop.isHidden = chrome <= 0 && !usesFloatingFrame
        if chrome > 0 || usesFloatingFrame {
            floatingBackdrop.alphaValue = usesFloatingFrame ? 1 : chrome
            floatingBackdrop.cornerRadius = resolved.floatingRadius
            floatingBackdrop.frame = rootRect(resolved.sidebarFrame, in: size)
            floatingBackdrop.fill.windowFillSize = size
            floatingBackdrop.fill.offsetInWindowFill = resolved.sidebarFrame.origin
        }

        let handleWidth = OrbitTokens.Metrics.Sidebar.resizeHandleWidth
        let resizable = isDocked && dockProgress >= 1 && floatProgress <= 0 && !isAnimating && allowsResize()
        resizeHandle.isHidden = !resizable
        if resizable {
            resizeHandle.frame = rootRect(CGRect(x: width.constant - handleWidth, y: 0, width: handleWidth, height: size.height), in: size)
            window?.invalidateCursorRects(for: resizeHandle)
        }

        trafficLights?.apply(centers: resolved.trafficLightCenters, visible: resolved.trafficLightsVisible,
                             isFullScreen: systemOwnsWindowButtons, animating: isAnimating || retainsOffscreenChrome)
        applyLibrarySidebarTransform()
        if wasOnScreen != resolved.isSidebarOnScreen || isAnimating || wasOnScreen == nil {
            onPresentationChange?()
        }
    }

    private func applyLibrarySidebarTransform() {
        guard let sidebar = libraryOutgoingSidebar else { return }
        let progress = Double(libraryProgress)
        (sidebar as? BrowserSidebarView)?.isLibraryInputSuppressed = progress > 0
        sidebar.alphaValue = LibraryMotion.sidebarOpacity(at: progress)
        guard let layer = sidebar.layer else { return }
        // AppKit owns the backing layer's anchor and position. Compose around its bounds centre
        // to reproduce Orbit's (0.5, 0.5) anchor without changing Auto Layout's layer geometry.
        let centre = CGPoint(x: sidebar.bounds.midX, y: sidebar.bounds.midY)
        var transform = CATransform3DMakeTranslation(centre.x, centre.y, 0)
        let scale = LibraryMotion.sidebarScale(at: progress)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -centre.x + LibraryMotion.sidebarTranslation(at: progress), -centre.y, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
    }

    private func set(_ constraint: NSLayoutConstraint?, _ value: CGFloat) {
        guard let constraint, constraint.constant != value else { return }
        constraint.constant = value
    }

    /// Converts a top-left rect into the unflipped root's coordinates.
    private func rootRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Hover regions

    private func updateHoverRegions(force: Bool = false) {
        guard let root else { return }
        let height = root.bounds.height
        let edge: CGRect?
        let keep: CGRect?
        if isDocked || hoverReveal.phase == .disabled {
            edge = nil
            keep = nil
        } else if hoverReveal.isRevealed {
            // The final floating panel plus the strip between it and the window edge.
            let maxX = OrbitTokens.Metrics.Sidebar.floatingInset + (width?.constant ?? OrbitTokens.Metrics.Sidebar.widthDefault)
            edge = nil
            keep = CGRect(x: 0, y: 0, width: maxX, height: height)
        } else {
            edge = CGRect(x: 0, y: 0, width: OrbitTokens.Motion.sidebarHoverEdgeTrigger, height: height)
            keep = nil
        }
        if force { hoverTracker.update(in: root, edge: nil, keep: nil) }
        hoverTracker.update(in: root, edge: edge, keep: keep)
    }

    // MARK: Theme

    /// Applies a Space theme: fill (cross-faded on Space switch), window appearance from its mode,
    /// window background for resize and full-screen transitions.
    func apply(theme newTheme: OrbitTokens.SpaceTheme, animated: Bool) {
        guard newTheme != theme else { return }
        let style = OrbitMotionStyle.resolve(animated: animated, canAnimate: canAnimate,
                                           reducedMotion: OrbitMotionPreferences.prefersReducedMotion)
        let previous = spaceSwipePaintedTheme ?? theme
        themeMotionSource = nil
        themeMotion.set(1)
        theme = newTheme
        if spaceSwipeBlend == nil {
            if style == .spring {
                // Orbit's theme producer consumes pager progress , rather than
                // running a wall-time fade for the nominal spring settling duration.
                themeMotionSource = previous
                themeMotion.onChange = { [weak self] progress in
                    guard let self, let source = themeMotionSource else { return }
                    paintSpaceTheme(.init(source: source, destination: theme, progress: progress))
                }
                themeMotion.onSettle = { [weak self] in
                    guard let self else { return }
                    themeMotionSource = nil
                    paintSpaceTheme(nil)
                }
                themeMotion.set(0)
                themeMotion.animate(to: 1, spring: OrbitTokens.Motion.spaceSwitchSidebar, in: root)
            } else {
                spaceSwipePaintedTheme = nil
                let fade = style == .crossfade ? OrbitTokens.Motion.reducedMotionCrossfade : nil
                themeFill.apply(newTheme, fade: fade)
                floatingBackdrop.fill.apply(newTheme, fade: fade)
            }
        }
        window?.appearance = OrbitAppearance.windowAppearance(for: newTheme.mode)
        updateWindowBackground()
    }

    /// Paints the captured endpoints without changing the stored/selected Space theme or material.
    func applySpaceSwipeBlend(_ blend: SpaceSwipeThemeBlend?) {
        themeMotionSource = nil
        themeMotion.set(1)
        spaceSwipeBlend = blend
        paintSpaceTheme(blend)
    }

    private func paintSpaceTheme(_ blend: SpaceSwipeThemeBlend?) {
        let painted = blend?.theme ?? theme
        spaceSwipePaintedTheme = blend == nil ? nil : painted
        themeFill.applyInteractiveTheme(painted)
        floatingBackdrop.fill.applyInteractiveTheme(painted)
        updateWindowBackground()
    }

    /// The blend is resolved once per swipe frame, not again for the window background.
    private var spaceSwipePaintedTheme: OrbitTokens.SpaceTheme?

    private func updateWindowBackground() {
        guard let window else { return }
        let stops = OrbitThemeGradient.normalizedStops((spaceSwipePaintedTheme ?? theme).stops, appearance: window.effectiveAppearance)
        // A solid NSWindow backing store would occlude behind-window sampling. Accessibility
        // fallback restores the exact opaque Space paint; the document card is unaffected.
        let opaque = !themeFill.glassStyle.usesMaterial
        let color = themeFill.glassStyle.usesMaterial ? NSColor.clear
            : (stops.first.flatMap { NSColor(cgColor: $0) } ?? OrbitTokens.Color.Surface.windowDefault)
        // Reassigning an equal background still invalidates the whole window on every swipe frame.
        if window.isOpaque != opaque { window.isOpaque = opaque }
        if window.backgroundColor != color { window.backgroundColor = color }
    }

    // MARK: Window notifications

    /// Observes a notification for the lifetime of the shell.
    func observe(_ name: Notification.Name, object: AnyObject?, _ action: @escaping @Sendable @MainActor () -> Void) {
        observers.add(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    private func observeWindow(_ window: NSWindow) {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, object: AnyObject? = window,
                _ action: @escaping @Sendable @MainActor (OrbitWindowShell) -> Void) {
            observers.add(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            })
        }
        on(NSWindow.willEnterFullScreenNotification) { shell in
            shell.isFullScreen = true
            shell.systemOwnsWindowButtons = true
            shell.applyGeometry()
            shell.onFullScreenChange?(true)
        }
        on(NSWindow.willExitFullScreenNotification) { shell in
            shell.isFullScreen = false
            shell.applyGeometry()
            shell.onFullScreenChange?(false)
        }
        on(NSWindow.didExitFullScreenNotification) { shell in
            shell.systemOwnsWindowButtons = false
            shell.applyGeometry()
        }
        on(NSWindow.didResizeNotification) { $0.applyGeometry() }
        on(NSWindow.didEndLiveResizeNotification) { $0.applyGeometry() }
        on(NSWindow.didBecomeKeyNotification) { $0.applyGeometry() }
        on(NSWindow.didResignKeyNotification) { shell in
            shell.hoverReveal.dismiss()
            shell.applyGeometry()
        }
        on(NSMenu.didBeginTrackingNotification, object: nil) { shell in
            shell.menuTrackingDepth += 1
            shell.hoverReveal.holdDidChange()
        }
        on(NSPopover.didCloseNotification, object: nil) { $0.hoverReveal.holdDidChange() }
        on(NSMenu.didEndTrackingNotification, object: nil) { shell in
            shell.menuTrackingDepth = max(0, shell.menuTrackingDepth - 1)
            shell.hoverReveal.holdDidChange()
        }
    }
}

/// Block observers must be removed explicitly; removal happens when the owning shell goes away.
final class OrbitNotificationObservers: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    func add(_ token: NSObjectProtocol) { tokens.append(token) }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// Removing a local event monitor is safe when the window-owned shell is released.
private final class OrbitSidebarReleaseMonitor: @unchecked Sendable {
    var token: Any?
    deinit { if let token { NSEvent.removeMonitor(token) } }
}
