import AppKit
import BrowserCore
import QuartzCore

/// Places engine-neutral host views. It never owns, reloads or disposes a document.
@MainActor
final class BrowserSplitView: NSView {
    enum NavigationAction { case back, forward, reload, address, siteControls, separate }
    struct Pane {
        let id: TabID
        /// Nil while the tab has no live surface in this window: the pane keeps its slot with a
        /// placeholder and nothing is loaded or reloaded on its behalf.
        let view: NSView?
        let address: String
        /// Page or custom title, used as the pane's accessibility label.
        var title: String? = nil
        var isOpenInAnotherWindow = false
        var canGoBack = false
        var canGoForward = false
    }
    private(set) var group: BrowserSplitGroup?
    private(set) var panes: [TabID: BrowserSplitPaneView] = [:]
    private(set) var dividers: [BrowserSplitDividerView] = []
    private var eventMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var dragOrigin: CGPoint?
    private var originalRatios: [Double]?
    private var draftRatios: [Double]?
    private var hasKeyboardDraft = false
    private var cancelledDividerGesture = false
    var onFocus: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var onResize: (([Double]) -> Void)?
    var onNavigate: ((TabID, NavigationAction) -> Void)?
    var canDrop: ((SidebarDragPayload) -> Bool)?
    var onDrop: ((SidebarDragPayload, BrowserSplitOrientation, Bool) -> Void)?
    var accent = OrbitTokens.ThemeAccent.defaultPurple
    private var active: TabID?
    private var singleView: NSView?
    private let dropHint = NSView()
    private let layoutMotion = OrbitTimedAnimator(value: 1)
    private var paneOrigins: [TabID: CGRect] = [:]
    private var pendingLayoutMotion = false


    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layoutMotion.onChange = { [weak self] _ in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
        }
        layoutMotion.onSettle = { [weak self] in self?.paneOrigins = [:] }
        registerForDraggedTypes([SidebarDragPayload.pasteboardType])
        dropHint.wantsLayer = true
        dropHint.layer?.cornerRadius = BrowserSplitTokens.radius
        dropHint.isHidden = true
        addSubview(dropHint)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopMonitoring() }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                let target: NSView?
                if event.type == .keyDown { target = self.window?.firstResponder as? NSView }
                else {
                    guard let point = self.superview?.convert(event.locationInWindow, from: nil) else { return }
                    target = self.hitTest(point)
                }
                if let target, let pane = self.panes.values.first(where: { target === $0 || target.isDescendant(of: $0) }), pane.id != self.active, !pane.isCloseControl(target) {
                    self.onFocus?(pane.id)
                }
            }
            return event
        }
    }

    private func stopMonitoring() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
    }

    /// An outgoing wrapper may stay attached for a snapshot, but may no longer intercept input
    /// or complete a divider gesture belonging to a presentation that is no longer current.
    func suspendInteraction() {
        layoutMotion.set(1)
        stopMonitoring()
        dragOrigin = nil
        originalRatios = nil
        draftRatios = nil; hasKeyboardDraft = false
        cancelledDividerGesture = true
        onFocus = nil
        onClose = nil
        onResize = nil
        onNavigate = nil
        canDrop = nil
        onDrop = nil
    }

    func presentSingle(_ host: NSView) {
        layoutMotion.set(1); paneOrigins = [:]; pendingLayoutMotion = false
        group = nil; draftRatios = nil; hasKeyboardDraft = false; dragOrigin = nil; originalRatios = nil
        for pane in panes.values { pane.removeFromSuperview() }; panes = [:]
        for divider in dividers { divider.removeFromSuperview() }; dividers = []
        if singleView !== host {
            singleView?.removeFromSuperview()
            host.removeFromSuperview()
            host.translatesAutoresizingMaskIntoConstraints = true
            addSubview(host, positioned: .below, relativeTo: dropHint)
            singleView = host
        }
        needsLayout = true
    }

    func present(_ group: BrowserSplitGroup, panes incoming: [Pane], active: TabID?, accent: OrbitTokens.ThemeAccent) {
        // Orbit's ordinary creation/close path publishes the new pane tree immediately.
        // Its animated layout branch is for changing ratios within an existing pane tree.
        let animateRatios = self.group?.tabIDs == group.tabIDs && self.group?.orientation == group.orientation
            && self.group?.ratios != group.ratios && dragOrigin == nil && !hasKeyboardDraft
        if animateRatios {
            paneOrigins = panes.mapValues(\.frame)
            pendingLayoutMotion = true
        } else if self.group != group {
            layoutMotion.set(1); paneOrigins = [:]; pendingLayoutMotion = false
        }
        singleView?.removeFromSuperview(); singleView = nil
        if self.group != group || self.active != active {
            if dragOrigin != nil { cancelledDividerGesture = true }
            dragOrigin = nil; originalRatios = nil; draftRatios = nil; hasKeyboardDraft = false
        }
        self.group = group
        self.accent = accent
        self.active = active
        let ids = Set(incoming.map(\.id))
        for id in Array(panes.keys) where !ids.contains(id) { panes.removeValue(forKey: id)?.removeFromSuperview() }
        for pane in incoming {
            let card: BrowserSplitPaneView
            if let existing = panes[pane.id] { card = existing }
            else {
                card = BrowserSplitPaneView(id: pane.id)
                card.onFocus = { [weak self] in self?.onFocus?(pane.id) }
                card.onClose = { [weak self] in self?.onClose?(pane.id) }
                card.onNavigate = { [weak self] action in self?.onNavigate?(pane.id, action) }
                panes[pane.id] = card
                addSubview(card, positioned: .below, relativeTo: dropHint)
            }
            card.present(pane.view, address: pane.address, title: pane.title,
                         isOpenInAnotherWindow: pane.isOpenInAnotherWindow)
            card.back.isEnabled = pane.canGoBack
            card.forward.isEnabled = pane.canGoForward
            card.reload.isEnabled = pane.view != nil
            card.setActive(pane.id == active, accent: accent)
        }
        if dividers.count != max(0, incoming.count - 1) {
            for divider in dividers { divider.removeFromSuperview() }
            dividers = (0..<max(0, incoming.count - 1)).map { index in
                let divider = BrowserSplitDividerView(index: index)
                divider.onDrag = { [weak self] point, ended in guard let self else { return }; self.dragDivider(index, point: self.convert(point, from: nil), ended: ended) }
                divider.onAdjust = { [weak self] adjustment in self?.adjustDivider(index, adjustment) ?? false }
                divider.onReset = { [weak self] in self?.resetDivider(index) }
                divider.onCommit = { [weak self] in self?.commitKeyboardDraft() }
                addSubview(divider)
                return divider
            }
        }
        for divider in dividers { divider.orientation = group.orientation }
        updateDividerValues()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if pendingLayoutMotion {
            pendingLayoutMotion = false
            if window?.isVisible == true, !inLiveResize, !OrbitMotionPreferences.prefersReducedMotion {
                layoutMotion.set(0)
                layoutMotion.animate(to: 1, timing: .split, in: self)
            } else { layoutMotion.set(1); paneOrigins = [:] }
        }
        let progress = CGFloat(layoutMotion.value)
        if let singleView {
            singleView.frame = bounds
            return
        }
        guard let group else { return }
        let geometry = BrowserSplitGeometry.layout(in: bounds, orientation: group.orientation,
                                                   ratios: draftRatios ?? group.ratios, gap: BrowserSplitTokens.gap)
        for (index, id) in group.tabIDs.enumerated() where geometry.panes.indices.contains(index) {
            let target = geometry.panes[index]
            let collapsed = group.orientation == .horizontal
                ? CGRect(x: target.maxX, y: target.minY, width: 0, height: target.height)
                : CGRect(x: target.minX, y: target.maxY, width: target.width, height: 0)
            panes[id]?.frame = Self.interpolate(from: paneOrigins[id] ?? collapsed, to: target, progress: progress)
        }
        for (index, divider) in dividers.enumerated() where geometry.dividers.indices.contains(index) {
            if let pane = panes[group.tabIDs[index]] {
                let target = geometry.dividers[index]
                divider.frame = group.orientation == .horizontal
                    ? CGRect(x: pane.frame.maxX, y: target.minY, width: target.width, height: target.height)
                    : CGRect(x: target.minX, y: pane.frame.maxY, width: target.width, height: target.height)
            }
        }
    }

    static func interpolate(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * progress,
               y: from.minY + (to.minY - from.minY) * progress,
               width: from.width + (to.width - from.width) * progress,
               height: from.height + (to.height - from.height) * progress)
    }

    func resetDivider(_ index: Int) {
        guard let group, group.ratios.indices.contains(index), group.ratios.indices.contains(index + 1) else { return }
        var ratios = group.ratios
        let half = (ratios[index] + ratios[index + 1]) / 2
        ratios[index] = half; ratios[index + 1] = half
        onResize?(ratios)
    }

    private func dragDivider(_ index: Int, point: CGPoint, ended: Bool) {
        // Direct manipulation follows the pointer; the 200 ms layout timing is only for commands.
        if layoutMotion.isAnimating { layoutMotion.set(1); paneOrigins = [:] }

        if cancelledDividerGesture {
            if ended { cancelledDividerGesture = false }
            return
        }
        guard let group else { return }
        if dragOrigin == nil { dragOrigin = point; originalRatios = group.ratios; hasKeyboardDraft = false }
        guard let origin = dragOrigin, let ratios = originalRatios else { return }
        let horizontal = group.orientation == .horizontal
        let delta = horizontal ? point.x - origin.x : point.y - origin.y
        draftRatios = BrowserSplitGeometry.resized(ratios, divider: index, delta: delta, available: availableExtent(ratios.count),
                                                   minimum: BrowserSplitTokens.minimumPaneExtent)
        needsLayout = true
        updateDividerValues()
        if ended {
            let result = draftRatios
            dragOrigin = nil; originalRatios = nil; draftRatios = nil
            if let result, result != ratios { onResize?(result) }
        }
    }

    private func availableExtent(_ count: Int) -> CGFloat {
        let horizontal = group?.orientation != .vertical
        return (horizontal ? bounds.width : bounds.height) - CGFloat(max(0, count - 1)) * BrowserSplitTokens.gap
    }

    /// Keyboard and VoiceOver resizing (AXSplitter). Arrow repeats only move the draft; the model
    /// receives one resize when the key is released, focus leaves or an AX action completes, so a
    /// held arrow is one undo record like a pointer drag. Ignored during a pointer drag.
    @discardableResult
    func adjustDivider(_ index: Int, _ adjustment: BrowserSplitDividerView.Adjustment) -> Bool {
        guard let group, dragOrigin == nil, group.ratios.indices.contains(index + 1) else { return false }
        let base = draftRatios ?? group.ratios
        let next: [Double]
        switch adjustment {
        case let .by(points):
            next = BrowserSplitGeometry.resized(base, divider: index, delta: points, available: availableExtent(base.count),
                                                minimum: BrowserSplitTokens.minimumPaneExtent)
        case .center:
            var centered = base
            let sum = base[index] + base[index + 1]
            centered[index] = sum / 2; centered[index + 1] = sum / 2
            next = centered
        }
        guard next != base else { return false }
        draftRatios = next
        hasKeyboardDraft = true
        needsLayout = true
        updateDividerValues()
        return true
    }

    func commitKeyboardDraft() {
        guard hasKeyboardDraft else { return }
        hasKeyboardDraft = false
        let result = draftRatios
        draftRatios = nil
        if let result, result != group?.ratios { onResize?(result) }
        updateDividerValues()
    }

    /// Divider positions as percentages of the whole split, for AXValue.
    private func updateDividerValues() {
        guard let group else { return }
        let ratios = draftRatios ?? group.ratios
        let total = ratios.reduce(0, +)
        guard total > 0 else { return }
        var cumulative = 0.0
        for (index, divider) in dividers.enumerated() where ratios.indices.contains(index) {
            cumulative += ratios[index]
            divider.setAccessibilityValue(NSNumber(value: Int((cumulative / total * 100).rounded())))
        }
    }

    /// Dragging a tab near an outer content edge selects the orientation and insertion side.
    /// The drop payload is process-local and carries no address or browsing content.
    private func edge(at point: CGPoint) -> (BrowserSplitOrientation, Bool)? {
        let band = min(BrowserSplitTokens.edgeBand, min(bounds.width, bounds.height) / 3)
        guard bounds.contains(point), band > 0 else { return nil }
        let distances: [(CGFloat, BrowserSplitOrientation, Bool)] = [
            (point.x - bounds.minX, .horizontal, true), (bounds.maxX - point.x, .horizontal, false),
            (point.y - bounds.minY, .vertical, true), (bounds.maxY - point.y, .vertical, false)]
        guard let closest = distances.min(by: { $0.0 < $1.0 }), closest.0 <= band else { return nil }
        return (closest.1, closest.2)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        guard let payload = SidebarDragPayload(pasteboard: sender.draggingPasteboard), canDrop?(payload) == true,
              let (orientation, leading) = edge(at: point) else { dropHint.isHidden = true; return [] }
        var hint = bounds
        if orientation == .horizontal { hint.size.width /= 2; if !leading { hint.origin.x += hint.width } }
        else { hint.size.height /= 2; if !leading { hint.origin.y += hint.height } }
        dropHint.frame = hint.insetBy(dx: 2, dy: 2)
        dropHint.layer?.backgroundColor = accent.strong.withAlphaComponent(0.22).cgColor
        dropHint.isHidden = false
        return .move
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropHint.isHidden = true }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { dropHint.isHidden = true }
        guard let payload = SidebarDragPayload(pasteboard: sender.draggingPasteboard), canDrop?(payload) == true,
              let (orientation, leading) = edge(at: convert(sender.draggingLocation, from: nil)) else { return false }
        onDrop?(payload, orientation, leading)
        return true
    }
}

@MainActor
final class BrowserSplitPaneView: NSView {
    let id: TabID
    let page = NSView()
    let clip = BrowserSplitClipView()
    let address = NSButton(title: "", target: nil, action: nil)
    let back = NSButton()
    let forward = NSButton()
    let reload = NSButton()
    let siteControls = NSButton()
    let splitToggle = NSButton()
    let close = NSButton()
    let line = NSView()
    let focusBorder = CALayer()
    private let placeholder = BrowserSplitPlaceholderView()
    private var isActive = false
    private var isBlank = false
    private var accent = OrbitTokens.ThemeAccent.defaultPurple
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?
    var onNavigate: ((BrowserSplitView.NavigationAction) -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(id: TabID) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerRadius = BrowserSplitTokens.radius
        clip.layer?.backgroundColor = OrbitTokens.Color.Surface.preview.resolvedCGColor(for: effectiveAppearance)
        addSubview(clip)
        clip.addSubview(page)
        address.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        address.contentTintColor = OrbitTokens.Color.Text.baseSecondary
        address.isBordered = false
        address.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        address.imagePosition = .imageLeading
        address.imageHugsTitle = true
        address.target = self
        address.action = #selector(editAddress)
        for (button, symbol, label, action) in [
            (back, "arrow.left", uiText("Back"), #selector(goBack)),
            (forward, "arrow.right", uiText("Forward"), #selector(goForward)),
            (reload, "arrow.clockwise", uiText("Reload"), #selector(reloadPage))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.contentTintColor = OrbitTokens.Color.Text.baseSecondary
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            clip.addSubview(button)
        }
        close.contentTintColor = OrbitTokens.Color.Text.baseSecondary
        let siteImage = OrbitGlyph.siteControlCenter
        siteImage.size = NSSize(width: 17, height: 17)
        for (button, image, label, action) in [
            (siteControls, Optional(siteImage), uiText("Site Controls"), #selector(showSiteControls)),
            (splitToggle, OrbitGlyph.symbol("square.split.2x1", pointSize: 15, weight: .medium),
             uiText("Separate Page from Split View"), #selector(separatePage))
        ] {
            button.image = image
            button.imageScaling = .scaleNone
            button.isBordered = false
            button.contentTintColor = OrbitTokens.Color.Text.baseSecondary
            button.target = self
            button.action = action
            button.isHidden = true
            button.setAccessibilityLabel(label)
            button.toolTip = label
            clip.addSubview(button)
        }
        address.lineBreakMode = .byTruncatingTail
        clip.addSubview(address)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: BrowserSplitStrings.closePane)
        close.isBordered = false
        close.target = self; close.action = #selector(closePane)
        clip.addSubview(close)
        line.wantsLayer = true
        line.layer?.backgroundColor = OrbitTokens.Color.Line.floatingScrimBorder.resolvedCGColor(for: effectiveAppearance)
        clip.addSubview(line)
        focusBorder.zPosition = 1
        focusBorder.cornerRadius = BrowserSplitTokens.radius
        focusBorder.borderWidth = BrowserSplitTokens.borderWidth
        focusBorder.opacity = 0
        layer?.addSublayer(focusBorder)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    func isCloseControl(_ target: NSView) -> Bool { target === close || target.isDescendant(of: close) }
    @objc private func closePane() { onClose?() }
    @objc private func goBack() { onNavigate?(.back) }
    @objc private func goForward() { onNavigate?(.forward) }
    @objc private func reloadPage() { onNavigate?(.reload) }
    @objc private func editAddress() { onNavigate?(.address) }
    @objc private func showSiteControls() {
        guard isActive, !isBlank else { return }
        onNavigate?(.siteControls)
    }
    @objc private func separatePage() {
        guard isActive, !isBlank else { return }
        onNavigate?(.separate)
    }
    override func mouseDown(with event: NSEvent) { onFocus?() }

    /// A nil host keeps this pane's slot with a placeholder; the live host replaces it when the
    /// surface becomes available, without any navigation from the Split layer.
    func present(_ host: NSView?, address text: String, title: String? = nil, isOpenInAnotherWindow: Bool = false) {
        isBlank = text.isEmpty || text == "about:blank"
        siteControls.isEnabled = host != nil && !isBlank
        splitToggle.isEnabled = host != nil && !isBlank
        page.isHidden = isBlank && host != nil
        let content = host ?? placeholder
        if page.subviews.first !== content {
            page.subviews.forEach { $0.removeFromSuperview() }
            content.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(content)
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: page.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: page.trailingAnchor), content.topAnchor.constraint(equalTo: page.topAnchor),
                content.bottomAnchor.constraint(equalTo: page.bottomAnchor)])
        }
        placeholder.message = isOpenInAnotherWindow ? BrowserSplitStrings.openInAnotherWindow : BrowserSplitStrings.notLoaded
        var displayed = text
        for prefix in ["https://", "http://"] where displayed.hasPrefix(prefix) { displayed = String(displayed.dropFirst(prefix.count)) }
        if displayed.hasSuffix("/"), URL(string: text)?.path == "/" { displayed.removeLast() }
        address.title = isBlank ? uiText("Search or Enter URL…") : displayed
        address.imagePosition = isBlank ? .noImage : .imageLeading
        address.setAccessibilityLabel(uiText("Address"))
        address.toolTip = text
        let label = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        setAccessibilityLabel(label.isEmpty ? BrowserSplitStrings.untitledPane : label)
        setAccessibilityHelp(host == nil ? placeholder.message : nil)
    }

    var isShowingPlaceholder: Bool { page.subviews.first === placeholder }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clip.layer?.backgroundColor = isBlank ? NSColor.clear.cgColor : OrbitTokens.Color.Surface.preview.resolvedCGColor(for: effectiveAppearance)
        line.layer?.backgroundColor = OrbitTokens.Color.Line.floatingScrimBorder.resolvedCGColor(for: effectiveAppearance)
        focusBorder.borderColor = accent.strong.resolvedCGColor(for: effectiveAppearance)
        if let layer {
            let shadow = isActive ? OrbitTokens.Shadow.splitActiveHalo : OrbitTokens.Shadow.contentCard
            shadow.apply(to: layer, isFlipped: isFlipped, appearance: effectiveAppearance)
        }
        CATransaction.commit()
    }

    func setActive(_ active: Bool, accent: OrbitTokens.ThemeAccent) {
        let wasActive = isActive
        self.accent = accent
        isActive = active
        refreshAppearance()
        reload.isHidden = !active || isBlank
        siteControls.isHidden = !active || isBlank
        splitToggle.isHidden = !active || isBlank
        if active != wasActive, window?.isVisible == true, !OrbitMotionPreferences.prefersReducedMotion {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = focusBorder.presentation()?.opacity ?? focusBorder.opacity
            animation.toValue = active ? 1 : 0
            animation.duration = BrowserSplitTokens.focusFade
            focusBorder.add(animation, forKey: "splitFocus")
        } else { focusBorder.removeAnimation(forKey: "splitFocus") }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        focusBorder.opacity = active ? 1 : 0
        CATransaction.commit()
        needsLayout = true
        setAccessibilityValue(active ? BrowserSplitStrings.activePane : BrowserSplitStrings.visiblePane)
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        let toolbar = min(bounds.height, BrowserSplitTokens.toolbarHeight)
        let compact = bounds.width < 300
        let step: CGFloat = compact ? 24 : 36
        back.frame = CGRect(x: 6, y: 4, width: 24, height: min(24, toolbar))
        forward.frame = back.frame.offsetBy(dx: step, dy: 0)
        reload.frame = back.frame.offsetBy(dx: step * 2, dy: 0)
        let leading: CGFloat = isActive ? 8 + step * 2 + 24 : 8 + step + 24
        let trailing: CGFloat = isActive && !isBlank ? 108 : 36
        address.frame = CGRect(x: leading, y: 3, width: max(0, bounds.width - leading - trailing), height: max(0, toolbar - 6))
        close.frame = CGRect(x: max(0, bounds.width - 33), y: 4, width: 24, height: min(24, toolbar))
        splitToggle.frame = close.frame.offsetBy(dx: -32, dy: 0)
        siteControls.frame = splitToggle.frame.offsetBy(dx: -36, dy: 0)
        line.frame = CGRect(x: 0, y: toolbar - 0.5, width: bounds.width, height: 0.5)
        page.frame = CGRect(x: 0, y: toolbar, width: bounds.width, height: max(0, bounds.height - toolbar))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        focusBorder.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: BrowserSplitTokens.radius,
                                  cornerHeight: BrowserSplitTokens.radius, transform: nil)
        CATransaction.commit()
    }
}

/// Honest stand-in while a member has no live surface here: no snapshot, no fake page content.
@MainActor
final class BrowserSplitPlaceholderView: NSView {
    private let label = NSTextField(labelWithString: "")
    var message: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = NSFont.systemFont(ofSize: 12) // estimate
        label.textColor = OrbitTokens.Color.Text.secondary
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24)])
    }
    required init?(coder: NSCoder) { nil }
}

/// Pointer, keyboard and VoiceOver handle between two adjacent panes (AXSplitter).
@MainActor
final class BrowserSplitDividerView: NSView {
    enum Adjustment: Equatable {
        case by(CGFloat)
        case center
    }
    static let keyboardStep: CGFloat = 10
    static let largeKeyboardStep: CGFloat = 30
    let index: Int
    var orientation: BrowserSplitOrientation = .horizontal {
        didSet {
            needsDisplay = true; window?.invalidateCursorRects(for: self)
            // A horizontal split stacks panes side by side, so its dividers are vertical.
            setAccessibilityOrientation(orientation == .horizontal ? .vertical : .horizontal)
        }
    }
    var onDrag: ((CGPoint, Bool) -> Void)?
    var onAdjust: ((Adjustment) -> Bool)?
    var onCommit: (() -> Void)?
    var onReset: (() -> Void)?
    private var hovered = false
    override var mouseDownCanMoveWindow: Bool { false }

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(.vertical)
        setAccessibilityLabel(BrowserSplitStrings.dividerLabel(before: index + 1, after: index + 2))
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 100))
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { nil }

    /// Reachable with Tab (full keyboard access), but a pointer press never takes focus from the page.
    override var acceptsFirstResponder: Bool {
        guard let type = NSApp.currentEvent?.type else { return true }
        return ![.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
    }
    override var canBecomeKeyView: Bool { true }
    override func resignFirstResponder() -> Bool {
        onCommit?()
        return super.resignFirstResponder()
    }
    override var focusRingMaskBounds: NSRect { handleRect.insetBy(dx: -2, dy: -2) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: handleRect.insetBy(dx: -2, dy: -2), xRadius: 2, yRadius: 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard modifiers.isEmpty || modifiers == .shift else { return super.keyDown(with: event) }
        let step = modifiers == .shift ? Self.largeKeyboardStep : Self.keyboardStep
        let horizontal = orientation == .horizontal
        let adjustment: Adjustment
        switch event.keyCode {
        case 123 where horizontal, 126 where !horizontal: adjustment = .by(-step) // ← / ↑
        case 124 where horizontal, 125 where !horizontal: adjustment = .by(step) // → / ↓
        case 115 where modifiers.isEmpty: adjustment = .center // Home
        default: return super.keyDown(with: event)
        }
        if onAdjust?(adjustment) != true { NSSound.beep() }
    }
    override func keyUp(with event: NSEvent) {
        if [115, 123, 124, 125, 126].contains(event.keyCode) { onCommit?() } else { super.keyUp(with: event) }
    }

    override func accessibilityPerformIncrement() -> Bool { performAccessibilityStep(Self.keyboardStep) }
    override func accessibilityPerformDecrement() -> Bool { performAccessibilityStep(-Self.keyboardStep) }
    private func performAccessibilityStep(_ step: CGFloat) -> Bool {
        let changed = onAdjust?(.by(step)) == true
        onCommit?()
        return changed
    }

    private var handleRect: CGRect {
        let horizontal = orientation == .horizontal
        return CGRect(x: bounds.midX - (horizontal ? 1 : 12), y: bounds.midY - (horizontal ? 12 : 1),
                      width: horizontal ? 2 : 24, height: horizontal ? 24 : 2)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: orientation == .horizontal ? .resizeLeftRight : .resizeUpDown) }
    override func draw(_ dirtyRect: NSRect) {
        (hovered ? OrbitTokens.Color.State.splitDividerHandleHovered : OrbitTokens.Color.State.splitDividerHandle).setFill()
        NSBezierPath(roundedRect: handleRect, xRadius: 1, yRadius: 1).fill()
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            if let onReset { onReset() } else { _ = onAdjust?(.center); onCommit?() }
            return
        }
        guard let window else { return }
        onDrag?(event.locationInWindow, false)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            onDrag?(next.locationInWindow, next.type == .leftMouseUp)
            if next.type == .leftMouseUp { break }
        }
    }
}

/// Pane geometry is expressed from the top edge, including inside the rounded clip.
@MainActor
final class BrowserSplitClipView: NSView {
    override var isFlipped: Bool { true }
}
