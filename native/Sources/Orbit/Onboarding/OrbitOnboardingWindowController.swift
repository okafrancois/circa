import AppKit
import BrowserCore
import QuartzCore

private typealias M = OrbitOnboardingMetrics

/// The first Space's theme as the theme step edits it.
struct OrbitOnboardingThemeTarget {
    let spaceID: SpaceID
    let profileID: ProfileID
    let stored: BrowserSpaceTheme?
    let commit: @MainActor (BrowserSpaceTheme?) async throws -> Void
    let registry: OrbitThemeEditorRegistry?
}

/// What the onboarding asks of the application. Tests and capture tools supply inert versions.
struct OrbitOnboardingServices {
    var persist: @MainActor (BrowserOnboardingRecord) -> Void = { _ in }
    var setSync: @MainActor (Bool) async -> Void = { _ in }
    var requestDefaultBrowser: @MainActor () async -> Void = {}
    var finish: @MainActor (BrowserOnboardingRecord, OrbitOnboardingWindowController) -> Void = { _, _ in }
    var sourceArtwork: @MainActor (OrbitOnboardingSource) -> (NSImage?, NSColor) = { _ in (nil, .clear) }
}

/// Non-closable 1280 × 800 window; the traffic lights stay grey (disabled) as measured.
@MainActor
final class OrbitOnboardingWindow: NSWindow {
    /// Centre of the first window button, from the window's top-left (measured 19.8, 23.7).
    static let firstButtonCenter = CGPoint(x: 19.8, y: 23.7)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: M.windowSize),
                   styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = OrbitOnboardingText.windowTitle
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        appearance = NSAppearance(named: .aqua)
        toolbar = NSToolbar(identifier: "orbit.onboarding")
        toolbarStyle = .unified
        toolbar?.showsBaselineSeparator = false
        identifier = NSUserInterfaceItemIdentifier("orbit-onboarding")
        tabbingMode = .disallowed
        collectionBehavior = [.fullScreenNone]
        // Measured hand-off: the main window replaces this one within a frame, without a fade.
        animationBehavior = .none
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        placeWindowButtons()
    }

    /// The buttons stay visible and grey: the onboarding is neither closed nor minimized.
    override func performClose(_ sender: Any?) { NSSound.beep() }
    override func performMiniaturize(_ sender: Any?) { NSSound.beep() }

    private func placeWindowButtons() {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttons.enumerated() {
            guard let button = standardWindowButton(type), let container = button.superview else { continue }
            button.isEnabled = false
            let center = CGPoint(x: Self.firstButtonCenter.x + CGFloat(index) * 19.8, y: Self.firstButtonCenter.y)
            // Container coordinates: its top edge is the window's top edge.
            let top = container.isFlipped ? center.y : container.bounds.height - center.y
            let origin = NSPoint(x: center.x - button.frame.width / 2, y: top - button.frame.height / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}

/// The first-run onboarding: welcome, import, sync, theme, default browser, finish.
@MainActor
final class OrbitOnboardingWindowController: NSWindowController {
    private(set) var flow: OrbitOnboardingFlow
    let services: OrbitOnboardingServices
    let background = OrbitOnboardingBackgroundView(frame: NSRect(origin: .zero, size: M.windowSize))
    let card = OrbitOnboardingCardView(frame: .zero)
    let welcome = OrbitOnboardingWelcomeView(frame: NSRect(origin: .zero, size: M.windowSize))
    let themeTarget: OrbitOnboardingThemeTarget?
    /// The intro shown before the welcome screen (a later lot); nil shows the welcome at once.
    var intro: ((OrbitOnboardingWindowController, @escaping @MainActor () -> Void) -> Void)?
    private(set) var themeEditor: OrbitThemeEditorController?
    private(set) var theme: BrowserSpaceTheme?
    private(set) var accent = OrbitOnboardingColors.accent
    private(set) var optionCards: [OrbitOnboardingOptionCard] = []
    private(set) var profileList: OrbitOnboardingProfileList?
    private(set) var isFinished = false
    private var importDocument: NSView?
    private let originalTheme: BrowserSpaceTheme?

    init(flow: OrbitOnboardingFlow, services: OrbitOnboardingServices, themeTarget: OrbitOnboardingThemeTarget?) {
        self.flow = flow
        self.services = services
        self.themeTarget = themeTarget
        originalTheme = themeTarget?.stored
        theme = themeTarget?.stored
        let window = OrbitOnboardingWindow()
        super.init(window: window)
        let content = NSView(frame: NSRect(origin: .zero, size: M.windowSize))
        content.wantsLayer = true
        background.autoresizingMask = [.width, .height]
        content.addSubview(background)
        welcome.autoresizingMask = [.width, .height]
        welcome.onContinue = { [weak self] in self?.primaryAction() }
        content.addSubview(welcome)
        card.setFrameOrigin(NSPoint(x: 157, y: M.windowSize.height - 126 - M.cardSize.height))
        content.addSubview(card)
        window.contentView = content
        card.primaryButton.onPress = { [weak self] in self?.primaryAction() }
        card.backButton.onPress = { [weak self] in self?.backAction() }
        card.skipButton.onPress = { [weak self] in self?.skipAction() }
        applyTheme(theme)
        render(direction: .forward, animated: false)
    }

    required init?(coder: NSCoder) { nil }

    var step: BrowserOnboardingRecord.Step { flow.step }

    /// Shows the window centred on the main screen and records the current step.
    func present() {
        guard let window else { return }
        window.center()
        services.persist(flow.record(.started))
        if let intro, flow.step == .welcome {
            welcome.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            intro(self) { [weak self] in self?.welcome.alphaValue = 1 }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    // MARK: Navigation

    var isTransitioning: Bool { card.runningTransitions > 0 || welcomeTransitions > 0 }
    private var welcomeTransitions = 0

    func primaryAction() {
        guard !isFinished, !isTransitioning, flow.canAdvance else { return }
        switch flow.step {
        case .sync:
            let enabled = flow.syncChoice == true
            Task { await services.setSync(enabled) }
        case .theme:
            closeThemeEditor()
        case .defaultBrowser:
            if flow.defaultBrowserChoice == true { Task { await services.requestDefaultBrowser() } }
        case .finish:
            isFinished = true
            closeThemeEditor()
            services.finish(flow.record(.completed), self)
            return
        default: break
        }
        let fromWelcome = flow.step == .welcome
        guard flow.advance() else { return }
        services.persist(flow.record(.started))
        if fromWelcome { pushFromWelcome() } else { render(direction: .forward, animated: true) }
    }

    func backAction() {
        guard !isFinished, !isTransitioning, flow.hasBack else { return }
        if flow.step == .theme { closeThemeEditor() }
        guard flow.goBack() else { return }
        services.persist(flow.record(.started))
        render(direction: .backward, animated: true)
    }

    /// Theme step only: leaves the first Space's theme as it was before onboarding.
    func skipAction() {
        guard flow.hasSkip, !isTransitioning else { return }
        closeThemeEditor()
        if theme != originalTheme, let target = themeTarget {
            applyTheme(originalTheme)
            let original = originalTheme
            Task { try? await target.commit(original) }
        }
        guard flow.advance() else { return }
        services.persist(flow.record(.started))
        render(direction: .forward, animated: true)
    }

    /// Welcome to the first card: the same push and cross-fade as between steps (inference).
    private func pushFromWelcome() {
        render(direction: .forward, animated: false)
        guard !OrbitMotionPreferences.prefersReducedMotion, let welcomeLayer = welcome.layer, let cardLayer = card.layer else {
            welcome.isHidden = true
            return
        }
        welcome.isHidden = false
        welcomeTransitions += 1
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.welcome.isHidden = true
                welcomeLayer.removeAllAnimations()
                cardLayer.removeAnimation(forKey: OrbitOnboardingCardView.pushKey)
                cardLayer.removeAnimation(forKey: OrbitOnboardingCardView.fadeKey)
                self.welcomeTransitions -= 1
            }
        }
        let out = M.push.animation(keyPath: "transform.translation.x")
        out.fromValue = 0
        out.toValue = -M.pushDistance
        out.isRemovedOnCompletion = false
        out.fillMode = .forwards
        welcomeLayer.add(out, forKey: OrbitOnboardingCardView.pushKey)
        let inbound = M.push.animation(keyPath: "transform.translation.x")
        inbound.fromValue = M.pushDistance
        inbound.toValue = 0
        cardLayer.add(inbound, forKey: OrbitOnboardingCardView.pushKey)
        for (layer, from, to) in [(welcomeLayer, Float(1), Float(0)), (cardLayer, Float(0), Float(1))] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = to
            fade.duration = M.crossFadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            layer.add(fade, forKey: OrbitOnboardingCardView.fadeKey)
        }
        CATransaction.commit()
    }

    /// Projects `flow` onto the window.
    func render(direction: OrbitOnboardingDirection, animated: Bool) {
        let isCard = flow.isCardStep
        welcome.isHidden = isCard
        card.isHidden = !isCard
        guard isCard else { return }
        card.layoutControls(hasBack: flow.hasBack, hasSkip: flow.hasSkip, animated: animated)
        card.primaryButton.title = flow.primaryTitle
        let (title, body, note) = text(for: flow.step)
        let page = OrbitOnboardingTextPage(title: title, body: body, note: note, hasBack: flow.hasBack)
        let right = makeRightPanel()
        card.show(page: page, right: right, direction: direction, animated: animated)
        refreshSelection()
        window?.recalculateKeyViewLoop()
    }

    private func text(for step: BrowserOnboardingRecord.Step) -> (String, String, String?) {
        switch step {
        case .welcome, .importSource:
            return (OrbitOnboardingText.importTitle, OrbitOnboardingText.importBody, OrbitOnboardingText.importNote)
        case .sync:
            let body = switch flow.syncAvailability {
            case .available: OrbitOnboardingText.syncBody
            case .signedOut: OrbitOnboardingText.syncSignedOut
            case .unavailable: OrbitOnboardingText.syncUnavailable
            }
            return (OrbitOnboardingText.syncTitle, body, nil)
        case .theme: return (OrbitOnboardingText.themeTitle, OrbitOnboardingText.themeBody, nil)
        case .defaultBrowser: return (OrbitOnboardingText.defaultTitle, OrbitOnboardingText.defaultBody, nil)
        case .finish:
            let importing = flow.importChoice.map { $0 != BrowserOnboardingRecord.ImportChoice.none } ?? false
            return (OrbitOnboardingText.finishTitle, importing ? OrbitOnboardingText.finishImportBody : OrbitOnboardingText.finishBody, nil)
        }
    }

    // MARK: Right panel

    private var panelSize: NSSize { NSSize(width: M.cardSize.width - M.rightPanelX, height: M.cardSize.height) }
    private var panelCenterX: CGFloat { M.rightPanelCenterX - M.rightPanelX }

    private func makeRightPanel() -> NSView {
        let panel = OrbitOnboardingFlippedView(frame: NSRect(origin: .zero, size: panelSize))
        panel.wantsLayer = true
        optionCards = []
        profileList = nil
        importDocument = nil
        switch flow.step {
        case .importSource: buildImportPanel(in: panel)
        case .sync:
            buildChoices(in: panel, yes: (OrbitOnboardingText.syncYesStrong, OrbitOnboardingText.syncYes),
                         no: (OrbitOnboardingText.syncNoStrong, OrbitOnboardingText.syncNo),
                         yesEnabled: flow.syncAvailability == .available,
                         select: { [weak self] value in self?.flow.selectSync(value) })
        case .theme: buildThemePanel(in: panel)
        case .defaultBrowser:
            buildChoices(in: panel, yes: (OrbitOnboardingText.defaultYesStrong, OrbitOnboardingText.defaultYes),
                         no: (OrbitOnboardingText.defaultNoStrong, OrbitOnboardingText.defaultNo), yesEnabled: true,
                         select: { [weak self] value in self?.flow.defaultBrowserChoice = value })
        case .welcome, .finish: break
        }
        return panel
    }

    private func buildChoices(in panel: NSView, yes: (String, String), no: (String, String), yesEnabled: Bool,
                              select: @escaping (Bool) -> Void) {
        let size = M.choiceCardSize
        let top = (panelSize.height - (2 * size.height + M.optionGap)) / 2
        for (index, (strong, detail)) in [yes, no].enumerated() {
            let card = OrbitOnboardingChoiceCard(strong: strong, detail: detail)
            card.setFrameOrigin(NSPoint(x: panelCenterX - size.width / 2, y: top + CGFloat(index) * (size.height + M.optionGap)))
            card.isEnabled = index == 1 || yesEnabled
            card.onSelect = { [weak self] in
                select(index == 0)
                self?.refreshSelection()
            }
            panel.addSubview(card)
            optionCards.append(card)
        }
    }

    private func buildImportPanel(in panel: NSView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: panelSize.width, height: M.importViewportBottom))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        let document = OrbitOnboardingFlippedView(frame: NSRect(origin: .zero, size: scroll.frame.size))
        document.setAccessibilityElement(true)
        document.setAccessibilityRole(.radioGroup)
        document.setAccessibilityLabel(OrbitOnboardingText.importListLabel)
        scroll.documentView = document
        panel.addSubview(scroll)
        importDocument = document
        layoutImportRows()
    }

    /// Rows top to bottom: detected sources in discovery order, the selected source's profiles below it,
    /// then "start fresh".
    private func layoutImportRows() {
        guard let document = importDocument else { return }
        for view in document.subviews { view.removeFromSuperview() }
        optionCards = []
        profileList = nil
        let rowSize = M.browserRowSize
        let x = panelCenterX - rowSize.width / 2
        var y = M.importFirstRowTop
        var cards: [OrbitOnboardingOptionCard] = []
        for source in flow.sources {
            let (icon, tint) = services.sourceArtwork(source)
            let row = OrbitOnboardingBrowserRow(title: source.name, icon: icon, tint: tint)
            row.setFrameOrigin(NSPoint(x: x, y: y))
            row.onSelect = { [weak self] in
                guard let self, flow.selectedSource != source else { return }
                flow.select(source: source)
                layoutImportRows()
                refreshSelection()
            }
            document.addSubview(row)
            cards.append(row)
            y += rowSize.height
            if flow.selectedSource == source, source.profiles.count > 1 {
                y += M.profileListGap
                let list = OrbitOnboardingProfileList(profiles: source.profiles, width: rowSize.width - 2 * M.profileListInset)
                list.setFrameOrigin(NSPoint(x: x + M.profileListInset, y: y))
                list.onSelect = { [weak self] directory in
                    self?.flow.select(profile: directory, of: source)
                    self?.refreshSelection()
                }
                document.addSubview(list)
                profileList = list
                y += list.frame.height
            }
            y += M.optionGap
        }
        let none = OrbitOnboardingBrowserRow(title: flow.sources.isEmpty ? OrbitOnboardingText.importNoneEmpty : OrbitOnboardingText.importNone,
                                             icon: nil, tint: .clear, multiline: true)
        none.setFrameOrigin(NSPoint(x: x, y: y))
        none.onSelect = { [weak self] in
            guard let self else { return }
            flow.importChoice = BrowserOnboardingRecord.ImportChoice.none
            layoutImportRows()
            refreshSelection()
        }
        document.addSubview(none)
        cards.append(none)
        y += rowSize.height + M.optionGap
        optionCards = cards
        document.setFrameSize(NSSize(width: document.frame.width, height: max(y, M.importViewportBottom)))
        window?.recalculateKeyViewLoop()
    }

    private func buildThemePanel(in panel: NSView) {
        guard let target = themeTarget else { return }
        let editor = OrbitThemeEditorController(spaceID: target.spaceID, profileID: target.profileID, stored: theme,
                                                initial: theme ?? BrowserSpaceThemePresets.default,
                                                commit: target.commit, replay: { _ in })
        editor.view.surfaceScope.isHidden = true
        // The card supplies the surface; the editor's own material belongs to its floating panel.
        editor.view.material.isHidden = true
        editor.onPreview = { [weak self] theme in self?.applyTheme(theme) }
        // Return continues to the next step; Escape keeps the editor open.
        editor.view.onDismiss = { [weak self] in
            if NSApp.currentEvent?.keyCode != 53 { self?.primaryAction() }
        }
        if let registry = target.registry, registry.canBeginEditing(spaceID: target.spaceID, profileID: target.profileID) {
            registry.track(editor)
        }
        themeEditor = editor
        let scaled = OrbitOnboardingFlippedView(frame: NSRect(x: panelCenterX - OrbitThemeEditorMetrics.pickerSize.width * M.themeEditorScale / 2,
                                                             y: M.themeEditorTop,
                                                             width: OrbitThemeEditorMetrics.pickerSize.width * M.themeEditorScale,
                                                             height: OrbitThemeEditorMetrics.pickerSize.height * M.themeEditorScale))
        scaled.wantsLayer = true
        scaled.setBoundsSize(OrbitThemeEditorMetrics.pickerSize)
        scaled.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.12)
            shadow.shadowBlurRadius = 16
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            return shadow
        }()
        let clip = OrbitOnboardingFlippedView(frame: NSRect(origin: .zero, size: OrbitThemeEditorMetrics.pickerSize))
        clip.wantsLayer = true
        clip.layer?.cornerRadius = OrbitThemeEditorMetrics.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = NSColor.white.cgColor
        clip.addSubview(editor.view)
        editor.view.setFrameOrigin(.zero)
        scaled.addSubview(clip)
        panel.addSubview(scaled)
    }

    private func closeThemeEditor() {
        guard let editor = themeEditor else { return }
        themeEditor = nil
        if editor.isEdited, !editor.failed { theme = editor.draft }
        editor.close(animated: false)
    }

    // MARK: Selection and theme

    private func refreshSelection() {
        switch flow.step {
        case .importSource:
            for (index, card) in optionCards.enumerated() {
                if index < flow.sources.count {
                    card.isSelected = flow.selectedSource == flow.sources[index]
                } else {
                    card.isSelected = flow.importChoice == BrowserOnboardingRecord.ImportChoice.none
                }
            }
            if case let .browser(_, profile) = flow.importChoice { profileList?.selected = profile }
        case .sync:
            for (index, card) in optionCards.enumerated() { card.isSelected = flow.syncChoice == (index == 0) }
        case .defaultBrowser:
            for (index, card) in optionCards.enumerated() { card.isSelected = flow.defaultBrowserChoice == (index == 0) }
        default: break
        }
        for card in optionCards { card.accent = accent }
        profileList?.accent = accent
        card.primaryButton.isEnabled = flow.canAdvance
    }

    /// Instant recolour of the backdrop, panel tint and accent controls (one frame).
    func applyTheme(_ newTheme: BrowserSpaceTheme?) {
        let themed = newTheme.map { !($0.colors.isEmpty && $0.presetID == BrowserSpaceThemePresets.defaultID) } ?? false
        theme = newTheme
        accent = themed ? OrbitOnboardingColors.accent(for: newTheme) : OrbitOnboardingColors.accent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.apply(theme: themed ? newTheme : nil)
        card.applyAccent(accent, themed: themed)
        for card in optionCards { card.accent = accent }
        profileList?.accent = accent
        CATransaction.commit()
    }

    // MARK: Test and capture support

    func select(optionAt index: Int) {
        guard optionCards.indices.contains(index) else { return }
        optionCards[index].onSelect?()
    }

    func selectProfile(_ directory: String) {
        guard let list = profileList else { return }
        list.onSelect?(directory)
    }
}

/// Top-left origin container.
final class OrbitOnboardingFlippedView: NSView {
    override var isFlipped: Bool { true }
}
