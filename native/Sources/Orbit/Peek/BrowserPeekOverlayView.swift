import AppKit
import BrowserShell
import QuartzCore

/// The Peek overlay above the whole browser window: a dimming scrim and a floating card made of a
/// page and three round controls beside it. It never owns a surface; it only places the view it is
/// given and reports user intents through closures. Non-generic so it can be tested alone.
@MainActor
final class BrowserPeekOverlayView: NSView {
    var onClose: (() -> Void)?
    var onOpenInTab: (() -> Void)?
    var onOpenInSplit: (() -> Void)?
    /// Starts the background transition when source capture is ready and the card starts moving.
    var onPresentationStart: (() -> Void)?
    /// A click on the scrim, outside the card.
    var onClickOutside: (() -> Void)?

    /// Corner radius of the scrim, matching the content card it covers.
    var scrimCornerRadius: CGFloat = 10 { didSet { scrim.layer?.cornerRadius = scrimCornerRadius } }
    var isSplitAvailable = false { didSet { toolbar.splitButton.isEnabled = isSplitAvailable } }

    /// Library pages use the full window and expose only close and tab promotion.
    var isLibraryBoost = false {
        didSet { toolbar.splitButton.isHidden = isLibraryBoost; needsLayout = true }
    }

    private let scrim = NSView()
    /// Carries the shadow; the clip view inside it rounds the page.
    private let cardShadow = PeekContainerView()
    private let cardClip = PeekContainerView()
    let toolbar = BrowserPeekToolbarView()
    private let pageContainer = PeekContainerView()
    /// Activated link bounds, in overlay coordinates.
    var sourceRect: NSRect?
    var sourceCornerRadius: CGFloat = 0
    var prepareSource: (() async -> (rect: NSRect, cornerRadius: CGFloat, image: CGImage?)?)?
    private var sourceTask: Task<Void, Never>?
    private let sourceImage = CALayer()
    private let promotionImage = CALayer()
    private var promotionViewport: (host: NSView, constraints: [NSLayoutConstraint])?
    /// The page geometry stays anchored to the content card while the scrim covers the sidebar.
    weak var contentAnchor: NSView?
    var presentationBounds: NSRect {
        guard !isLibraryBoost, let contentAnchor else { return bounds }
        let leading = convert(contentAnchor.bounds, from: contentAnchor).minX
        return NSRect(x: leading, y: bounds.minY, width: max(0, bounds.maxX - leading), height: bounds.height)
    }
    var scrimColor = BrowserPeekStyle.scrim { didSet { applyAppearanceColors() } }
    private(set) var isShown = false
    /// Increments for every show/hide so a stale animation completion does nothing.
    private var transitionGeneration = 0
    /// The completion of the close or promotion animation in progress, run exactly once.
    private var pendingExit: (generation: Int, completion: () -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        setAccessibilityIdentifier("peek-overlay")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("Peek"))

        scrim.wantsLayer = true
        scrim.layer?.cornerRadius = scrimCornerRadius
        scrim.layer?.masksToBounds = true
        addSubview(scrim)

        cardShadow.wantsLayer = true
        cardShadow.layer?.masksToBounds = false
        addSubview(cardShadow)

        cardClip.wantsLayer = true
        cardClip.layer?.cornerRadius = BrowserPeekStyle.cardRadius
        cardClip.layer?.masksToBounds = true
        cardClip.translatesAutoresizingMaskIntoConstraints = false
        cardShadow.addSubview(cardClip)

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.wantsLayer = true
        promotionImage.contentsGravity = .resize
        promotionImage.actions = Dictionary(uniqueKeysWithValues:
            ["bounds", "position", "contents", "cornerRadius", "masksToBounds", "zPosition", "onOrderIn", "onOrderOut"]
                .map { ($0, NSNull()) })
        addSubview(toolbar)
        layer?.addSublayer(promotionImage)
        promotionImage.zPosition = 1
        cardClip.addSubview(pageContainer)
        sourceImage.contentsGravity = .resize
        cardClip.layer?.addSublayer(sourceImage)
        NSLayoutConstraint.activate([
            cardClip.leadingAnchor.constraint(equalTo: cardShadow.leadingAnchor),
            cardClip.trailingAnchor.constraint(equalTo: cardShadow.trailingAnchor),
            cardClip.topAnchor.constraint(equalTo: cardShadow.topAnchor),
            cardClip.bottomAnchor.constraint(equalTo: cardShadow.bottomAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: cardClip.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: cardClip.trailingAnchor),
            pageContainer.topAnchor.constraint(equalTo: cardClip.topAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: cardClip.bottomAnchor)
        ])
        toolbar.closeButton.target = self
        toolbar.closeButton.action = #selector(closeAction(_:))
        toolbar.openInTabButton.target = self
        toolbar.openInTabButton.action = #selector(openInTabAction(_:))
        toolbar.splitButton.target = self
        toolbar.splitButton.action = #selector(openInSplitAction(_:))
        toolbar.splitButton.isEnabled = isSplitAvailable
        applyAppearanceColors()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The card's frame in this view's coordinates.
    var cardFrame: NSRect {
        let bounds = presentationBounds
        guard bounds.width > 240, bounds.height > 160 else { return bounds }
        return bounds.insetBy(dx: (bounds.width - bounds.width * BrowserPeekMotion.widthFraction) / 2,
                              dy: BrowserPeekMotion.verticalInset)
    }

    override func layout() {
        super.layout()
        scrim.frame = bounds
        cardShadow.frame = cardFrame
        // AppKit resets backing-layer geometry when assigning the view frame. Establish the
        // pivot afterwards, so bounds-height and transform animations share Orbit's centre.
        cardShadow.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        cardShadow.layer?.position = CGPoint(x: cardFrame.midX, y: cardFrame.midY)
        let metrics = OrbitTokens.Metrics.Peek.self
        let x = min(presentationBounds.maxX - metrics.controlDiameter - 4, cardFrame.maxX + metrics.controlGapFromPanel)
        toolbar.frame = NSRect(x: x, y: cardFrame.minY + metrics.controlTopInset,
                               width: metrics.controlDiameter, height: metrics.controlPitch * 2 + metrics.controlDiameter)
        updateShadowPath()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            scrim.layer?.backgroundColor = scrimColor.cgColor
            cardClip.layer?.backgroundColor = BrowserPeekStyle.cardBackground.cgColor
            cardClip.layer?.borderColor = BrowserPeekStyle.hairline.cgColor
            cardShadow.layer?.shadowColor = BrowserPeekStyle.shadowColor.cgColor
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        cardClip.layer?.borderWidth = 1 / scale
        cardShadow.layer?.shadowOpacity = 1
        // Flipped view: positive y goes down the screen.
        cardShadow.layer?.shadowOffset = CGSize(width: 0, height: BrowserPeekStyle.shadowOffsetY)
        cardShadow.layer?.shadowRadius = BrowserPeekStyle.shadowBlur / 2
        toolbar.applyAppearanceColors()
    }

    private func updateShadowPath() {
        cardShadow.layer?.shadowPath = CGPath(roundedRect: cardShadow.bounds, cornerWidth: BrowserPeekStyle.cardRadius,
                                              cornerHeight: BrowserPeekStyle.cardRadius, transform: nil)
    }

    // MARK: Hit testing: clicks outside the card belong to the overlay

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isShown else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if cardShadow.frame.contains(local) || toolbar.frame.contains(local) { return super.hitTest(point) }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if !cardShadow.frame.contains(local) && !toolbar.frame.contains(local) { onClickOutside?() }
    }

    override func scrollWheel(with event: NSEvent) {
        // The page behind Peek does not scroll.
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: Presentation

    /// Installs `hostView` in the card and fades the overlay in. The view is placed edge to edge
    /// below the toolbar; placing it again does nothing, so the document is never reloaded.
    func show(_ hostView: NSView, animated: Bool) {
        restorePromotionViewport()
        sourceTask?.cancel()
        transitionGeneration &+= 1
        pendingExit = nil
        place(hostView)
        isHidden = false
        isShown = true
        cardShadow.layer?.removeAllAnimations()
        cardClip.layer?.removeAllAnimations()
        pageContainer.layer?.removeAllAnimations()
        scrim.layer?.removeAllAnimations()
        toolbar.layer?.removeAllAnimations()
        alphaValue = 1
        for view in [cardShadow, scrim, toolbar, pageContainer] {
            view.alphaValue = 1
            view.layer?.opacity = 1
        }
        sourceImage.removeAllAnimations()
        sourceImage.contents = nil
        sourceImage.opacity = 0
        promotionImage.removeAllAnimations()
        promotionImage.removeFromSuperlayer()
        layer?.addSublayer(promotionImage)
        promotionImage.zPosition = 1
        promotionImage.cornerRadius = 0
        promotionImage.masksToBounds = false
        promotionImage.contents = nil
        cardShadow.isHidden = false
        toolbar.isHidden = false
        pageContainer.alphaValue = 1
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard animated else { onPresentationStart?(); return }
        if BrowserPeekStyle.prefersReducedMotion {
            onPresentationStart?()
            fade(layer: cardShadow.layer, from: 0, to: 1, duration: BrowserPeekStyle.reducedMotionCrossfade)
            fade(layer: scrim.layer, from: 0, to: 1, duration: BrowserPeekStyle.reducedMotionCrossfade)
            return
        }
        let generation = transitionGeneration
        if let prepareSource, window?.isVisible == true {
            cardShadow.alphaValue = 0
            toolbar.alphaValue = 0
            scrim.alphaValue = 0
            sourceTask = Task { [weak self] in
                let source = await prepareSource()
                guard let self, !Task.isCancelled, transitionGeneration == generation, isShown else { return }
                if let source {
                    sourceRect = source.rect
                    sourceCornerRadius = source.cornerRadius
                    sourceImage.contents = source.image
                }
                animatePresentation()
            }
        } else { animatePresentation() }
    }

    private func animatePresentation() {
        onPresentationStart?()
        cardShadow.alphaValue = 1
        toolbar.alphaValue = 1
        scrim.alphaValue = 1
        let spring = isLibraryBoost ? BrowserPeekMotion.libraryPresent : BrowserPeekStyle.presentSpring
        animateCard(fromSource: true, spring: spring)
        springOpacity(scrim.layer, from: 0, to: 1, spring: spring)
        springOpacity(toolbar.layer, from: 0, to: 1, spring: spring)
        if sourceImage.contents != nil {
            let geometry = sourceGeometry
            sourceImage.frame = NSRect(x: 0, y: 0, width: cardFrame.width, height: geometry.height)
            springOpacity(sourceImage, from: 1, to: 0, spring: BrowserPeekMotion.sourcePresent)
            springOpacity(pageContainer.layer, from: 0, to: 1, spring: spring)
        }
    }

    /// Replaces the page shown in the card without animation.
    func place(_ hostView: NSView) {
        guard hostView.superview !== pageContainer else { return }
        for subview in pageContainer.subviews { subview.removeFromSuperview() }
        hostView.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor)
        ])
    }

    /// The view the card currently shows, if any.
    var placedView: NSView? { pageContainer.subviews.first }

    /// The page area below the toolbar, where page-level bars (find) are anchored.
    var pageArea: NSView { pageContainer }

    /// Fades the overlay out; `completion` runs once, when the animation ends, unless another
    /// presentation started meanwhile.
    func hide(animated: Bool, completion: @escaping () -> Void = {}) {
        guard isShown else { completion(); return }
        beginExit(animated: animated, completion: completion) {
            if BrowserPeekStyle.prefersReducedMotion {
                let duration = BrowserPeekStyle.reducedMotionCrossfade
                fade(layer: cardShadow.layer, from: 1, to: 0, duration: duration, holds: true)
                fade(layer: scrim.layer, from: 1, to: 0, duration: duration, holds: true)
                return duration
            }
            let spring = BrowserPeekStyle.dismissSpring
            animateCard(fromSource: false, spring: spring)
            springOpacity(scrim.layer, from: scrim.layer?.presentation()?.opacity ?? 1, to: 0, spring: spring, holds: true)
            springOpacity(toolbar.layer, from: toolbar.layer?.presentation()?.opacity ?? 1, to: 0, spring: spring, holds: true)
            if sourceImage.contents != nil {
                springOpacity(sourceImage, from: sourceImage.presentation()?.opacity ?? 0, to: 1,
                              spring: BrowserPeekMotion.sourceDismiss, delay: BrowserPeekMotion.sourceDismissDelay, holds: true)
                springOpacity(pageContainer.layer, from: pageContainer.layer?.presentation()?.opacity ?? 1, to: 0, spring: spring, holds: true)
            }
            return spring.animation(keyPath: "transform").duration
        }
    }

    /// Keeps the last painted frame attached while the live surface changes parents.
    func retainPromotionImage(_ image: CGImage) {
        // This layer starts empty. Its geometry and contents must be ready before the live
        // host leaves; implicit layer actions would grow it from zero during the transfer.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if BrowserPeekStyle.prefersReducedMotion {
            promotionImage.removeFromSuperlayer()
            pageContainer.layer?.addSublayer(promotionImage)
            promotionImage.frame = pageContainer.bounds
            promotionImage.cornerRadius = 0
            promotionImage.masksToBounds = false
        } else {
            promotionImage.frame = cardFrame
            promotionImage.cornerRadius = BrowserPeekStyle.cardRadius
            promotionImage.masksToBounds = true
        }
        promotionImage.contents = image
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Reflow behind the retained frame while the old card still clips the live host.
    func preparePromotionViewport(_ host: NSView, size: NSSize) {
        restorePromotionViewport()
        guard host.superview === pageContainer, size.width > 0, size.height > 0 else { return }
        let constraints = pageContainer.constraints.filter { $0.firstItem === host || $0.secondItem === host }
        promotionViewport = (host, constraints)
        NSLayoutConstraint.deactivate(constraints)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = []
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
    }

    func restorePromotionViewport(restoreLayout: Bool = true) {
        guard let pending = promotionViewport else { return }
        promotionViewport = nil
        guard restoreLayout, pending.host.superview === pageContainer else { return }
        pending.host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(pending.constraints)
        pageContainer.layoutSubtreeIfNeeded()
    }

    /// The already reflowed image covers the first paint in the receiver's native hierarchy.
    func retainDestinationImage(_ image: CGImage, in destination: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        promotionImage.frame = destination
        promotionImage.contents = image
        promotionImage.cornerRadius = OrbitTokens.Radius.contentCard
        promotionImage.masksToBounds = true
        cardShadow.isHidden = true
        toolbar.isHidden = true
        CATransaction.commit()
        CATransaction.flush()
    }

    func discardPromotionImage() {
        promotionImage.contents = nil
    }

    /// Promotion changes the card and its controls together when the receiver is ready.
    /// Keep the accessibility crossfade for callers that explicitly reduce motion.
    func completePromotion(completion: @escaping () -> Void = {}) {
        guard isShown, BrowserPeekStyle.prefersReducedMotion else {
            hide(animated: false, completion: completion)
            return
        }
        beginExit(animated: true, completion: completion) {
            let duration = BrowserPeekStyle.reducedMotionCrossfade
            fade(layer: cardShadow.layer, from: 1, to: 0, duration: duration, holds: true)
            fade(layer: scrim.layer, from: 1, to: 0, duration: duration, holds: true)
            return duration
        }
    }

    /// True between the start of a close or promotion animation and its completion.
    var isExiting: Bool { pendingExit != nil }

    private func beginExit(animated: Bool, completion: @escaping () -> Void, animate: () -> CFTimeInterval) {
        sourceTask?.cancel()
        sourceTask = nil
        cardShadow.alphaValue = 1
        toolbar.alphaValue = 1
        scrim.alphaValue = 1
        isShown = false
        transitionGeneration &+= 1
        let generation = transitionGeneration
        pendingExit = (generation, completion)
        guard animated, window != nil else {
            finishExit(generation)
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.finishExit(generation) } }
        let duration = animate()
        CATransaction.commit()
        // Core Animation may not complete animations of a window that is off screen or occluded:
        // the exit ends at the latest shortly after the animation's own duration.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration + BrowserPeekStyle.exitCompletionGrace))
            self?.finishExit(generation)
        }
    }

    private func finishExit(_ generation: Int) {
        guard transitionGeneration == generation, let exit = pendingExit, exit.generation == generation else { return }
        pendingExit = nil
        isHidden = true
        cardShadow.layer?.removeAllAnimations()
        cardClip.layer?.removeAllAnimations()
        scrim.layer?.removeAllAnimations()
        toolbar.layer?.removeAllAnimations()
        pageContainer.layer?.removeAllAnimations()
        sourceImage.removeAllAnimations()
        promotionImage.removeAllAnimations()
        promotionImage.contents = nil
        exit.completion()
    }

    private func fade(layer: CALayer?, from: Float, to: Float, duration: CFTimeInterval, holds: Bool = false) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: to > from ? .easeOut : .easeIn)
        if holds {
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
        }
        layer?.add(fade, forKey: "peek.fade")
    }

    private func springOpacity(_ layer: CALayer?, from: Float, to: Float, spring: OrbitTokens.Spring,
                               delay: Double = 0, holds: Bool = false) {
        guard let layer else { return }
        let animation = spring.animation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        if delay > 0 { animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay }
        animation.fillMode = holds ? .both : .backwards
        animation.isRemovedOnCompletion = !holds
        layer.opacity = to
        layer.add(animation, forKey: "peek.opacity")
    }

    private func animateCard(fromSource: Bool, spring: OrbitTokens.Spring) {
        guard let layer = cardShadow.layer else { return }
        let source = resolvedSourceRect
        let geometry = sourceGeometry
        let sourceBounds = NSRect(x: 0, y: 0, width: cardFrame.width, height: geometry.height)
        let sourcePosition = NSPoint(x: cardFrame.midX, y: cardFrame.minY + geometry.height / 2)
        let translation = CATransform3DMakeTranslation(source.midX - sourcePosition.x, source.midY - sourcePosition.y, 0)
        let sourceScale = CATransform3DScale(translation, geometry.scale, geometry.scale, 1)
        func add(_ layer: CALayer, key: String, source: Any, destination: Any, current: Any?) {
            let animation = spring.animation(keyPath: key)
            animation.fromValue = fromSource ? source : current ?? destination
            animation.toValue = fromSource ? destination : source
            animation.fillMode = .both
            animation.isRemovedOnCompletion = fromSource
            layer.add(animation, forKey: "peek." + key)
        }
        add(layer, key: "transform", source: NSValue(caTransform3D: sourceScale),
            destination: NSValue(caTransform3D: CATransform3DIdentity),
            current: layer.presentation().map { NSValue(caTransform3D: $0.transform) })
        add(layer, key: "position", source: NSValue(point: sourcePosition), destination: NSValue(point: layer.position),
            current: layer.presentation().map { NSValue(point: $0.position) })
        add(layer, key: "bounds", source: NSValue(rect: sourceBounds), destination: NSValue(rect: layer.bounds),
            current: layer.presentation().map { NSValue(rect: $0.bounds) })
        if let clip = cardClip.layer {
            let radius = sourceCornerRadius / geometry.scale
            add(clip, key: "cornerRadius", source: radius, destination: BrowserPeekStyle.cardRadius,
                current: clip.presentation()?.cornerRadius)
            add(clip, key: "bounds", source: NSValue(rect: sourceBounds), destination: NSValue(rect: clip.bounds),
                current: clip.presentation().map { NSValue(rect: $0.bounds) })
            let position = NSPoint(x: clip.anchorPoint.x * sourceBounds.width, y: clip.anchorPoint.y * sourceBounds.height)
            add(clip, key: "position", source: NSValue(point: position), destination: NSValue(point: clip.position),
                current: clip.presentation().map { NSValue(point: $0.position) })
        }
        let radius = sourceCornerRadius / geometry.scale
        let path = CGPath(roundedRect: sourceBounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        add(layer, key: "shadowPath", source: path, destination: layer.shadowPath ?? path, current: layer.presentation()?.shadowPath)
        if let controls = toolbar.layer {
            let position = NSPoint(x: controls.position.x + source.maxX - cardFrame.maxX,
                                   y: controls.position.y + source.minY - cardFrame.minY)
            add(controls, key: "position", source: NSValue(point: position), destination: NSValue(point: controls.position),
                current: controls.presentation().map { NSValue(point: $0.position) })
        }
    }

    private var resolvedSourceRect: NSRect {
        sourceRect ?? BrowserPeekMotion.pointerFallback(at: NSPoint(x: cardFrame.midX, y: cardFrame.midY))
    }

    private var sourceGeometry: (scale: CGFloat, height: CGFloat) {
        BrowserPeekMotion.sourceGeometry(source: resolvedSourceRect, card: cardFrame)
    }

    // MARK: Toolbar actions

    @objc private func closeAction(_ sender: Any?) { onClose?() }
    @objc private func openInTabAction(_ sender: Any?) { onOpenInTab?() }
    @objc private func openInSplitAction(_ sender: Any?) { onOpenInSplit?() }

    // MARK: Diagnostics

    var displayedAddress: String { toolbar.addressLabel.stringValue }
}

@MainActor
private final class PeekContainerView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class BrowserPeekToolbarView: NSView {
    override var isFlipped: Bool { true }
    let addressLabel = NSTextField(labelWithString: "")
    let splitButton = BrowserPeekToolbarButton(symbol: "rectangle.split.2x1", label: uiText("Open in Split View"), identifier: "peek-open-in-split")
    let openInTabButton = BrowserPeekToolbarButton(symbol: "arrow.up.left.and.arrow.down.right", label: uiText("Open in Tab"), identifier: "peek-open-in-tab")
    let closeButton = BrowserPeekToolbarButton(symbol: "xmark", label: uiText("Close Peek (Escape)"), identifier: "peek-close")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addressLabel.font = BrandTextStyle.ui.font(size: 13)
        addressLabel.setAccessibilityIdentifier("peek-address")
        addressLabel.isHidden = true
        addSubview(addressLabel)
        for (index, button) in [closeButton, openInTabButton, splitButton].enumerated() {
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(index) * OrbitTokens.Metrics.Peek.controlPitch)
            ])
        }
        applyAppearanceColors()
    }

    required init?(coder: NSCoder) { nil }

    func applyAppearanceColors() {
        addressLabel.textColor = BrowserPeekStyle.toolbarForeground
        for button in [splitButton, openInTabButton, closeButton] { button.applyAppearanceColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    /// Shows the host and path of the Peek document; the full address is in the tooltip.
    func update(url: URL?, title: String?) {
        guard let url else {
            addressLabel.stringValue = ""
            addressLabel.toolTip = nil
            return
        }
        let host = url.host ?? url.absoluteString
        let path = url.path == "/" ? "" : url.path
        addressLabel.stringValue = host + path
        addressLabel.toolTip = [title, url.absoluteString].compactMap { $0 }.joined(separator: "\n")
    }
}

@MainActor
final class BrowserPeekToolbarButton: NSButton {
    // Symbol images carry baseline alignment insets. These custom discs constrain their painted
    // frame, so AppKit must not expand that frame around the symbol's alignment rectangle.
    override var alignmentRectInsets: NSEdgeInsets { .init() }

    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(symbol: String, label: String, identifier: String) {
        super.init(frame: .zero)
        image = OrbitIcon.image(sfName: symbol, pointSize: OrbitTokens.Metrics.Peek.controlGlyphSize, accessibilityDescription: label, weight: .medium)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: OrbitTokens.Metrics.Peek.controlGlyphSize, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: BrowserPeekStyle.buttonSize),
            heightAnchor.constraint(equalToConstant: BrowserPeekStyle.buttonSize)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool {
        didSet { applyAppearanceColors() }
    }

    func applyAppearanceColors() {
        contentTintColor = isEnabled ? BrowserPeekStyle.toolbarForeground : BrowserPeekStyle.toolbarDisabled
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        (isHovered && isEnabled ? BrowserPeekStyle.buttonHover : BrowserPeekStyle.buttonBackground).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        super.draw(dirtyRect)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
