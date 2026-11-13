import AppKit
import BrowserCore
import QuartzCore
import BrowserShell
import Combine

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
    var cachedFavicon: @MainActor (URL) -> NSImage? = { _ in nil }
    var favicon: @MainActor (URL) async -> NSImage? = { _ in nil }
    var observeImportProgress: @MainActor (@escaping @MainActor (OrbitOnboardingImportStatus) -> Void) -> Void = { _ in }
    var waitsForBrowserPreview = false
    var persist: @MainActor (BrowserOnboardingRecord) -> Void = { _ in }
    var setSync: @MainActor (Bool) async -> Void = { _ in }
    var requestDefaultBrowser: @MainActor () async -> Void = {}
    var isDefaultBrowser: @MainActor () -> Bool? = { nil }
    var loadFavourites: @MainActor (OrbitOnboardingFlow) async throws -> [BrowserOnboardingFavourite] = { _ in BrowserOnboardingFavourite.starter }
    var prepareFinish: @MainActor (OrbitOnboardingFlow) async throws -> Double? = { _ in nil }
    var importSummary: @MainActor () -> BrowserOnboardingRecord.ImportSummary? = { nil }
    var enteredFinish: @MainActor (OrbitOnboardingFlow) -> Void = { _ in }
    var finish: @MainActor (BrowserOnboardingRecord, OrbitOnboardingWindowController) -> Void = { _, _ in }
    var sourceArtwork: @MainActor (OrbitOnboardingSource) -> (NSImage?, NSColor) = { _ in (nil, .clear) }
}

/// Non-closable first-run window with disabled traffic lights.
@MainActor
final class OrbitOnboardingWindow: NSWindow {
    /// Centre of the first window button, from the window's top-left (measured 19.8, 23.7).
    static let firstButtonCenter = CGPoint(x: 34, y: 29.2)

    var onPrimaryAction: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ["\r", "\n"].contains(event.charactersIgnoringModifiers ?? ""), event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onPrimaryAction?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if ["\r", "\n"].contains(event.charactersIgnoringModifiers ?? "") { onPrimaryAction?() }
        else { super.keyDown(with: event) }
    }

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
            let center = CGPoint(x: Self.firstButtonCenter.x + CGFloat(index) * 26.84, y: Self.firstButtonCenter.y)
            // Container coordinates: its top edge is the window's top edge.
            let top = container.isFlipped ? center.y : container.bounds.height - center.y
            let origin = NSPoint(x: center.x - button.frame.width / 2, y: top - button.frame.height / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}

/// The seven-step first-run window and its real browser hand-off.
@MainActor
final class OrbitOnboardingWindowController: NSWindowController {
    private(set) var flow: OrbitOnboardingFlow
    var services: OrbitOnboardingServices
    let background = OrbitOnboardingBackgroundView(frame: NSRect(origin: .zero, size: M.windowSize))
    let card = OrbitOnboardingCardView(frame: .zero)
    let finishStage = OrbitOnboardingFinishView(frame: NSRect(origin: .zero, size: M.windowSize))
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
    private var systemColors: AnyCancellable?
    private weak var previewWindow: NSWindow?
    private var previewContent: NSView?
    private let stageCounter = NSTextField(labelWithString: "")
    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    private var lastProgressValue: CGFloat?
    private var choicesTop: CGFloat = 240
    private var selectionNote: NSTextField?
    private var importProgressView: OrbitOnboardingImportProgressView?
    private var busy = false
    private var favouritesView: OrbitOnboardingFavouritesView?
    private var promptMock: NSView?
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
        window.onPrimaryAction = { [weak self] in self?.primaryAction() }
        let content = NSView(frame: NSRect(origin: .zero, size: M.windowSize))
        content.wantsLayer = true
        content.layer?.borderWidth = 2
        content.layer?.borderColor = BrandPalette.ink.cgColor
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        content.addSubview(background)
        welcome.autoresizingMask = [.width, .height]
        welcome.onContinue = { [weak self] in self?.primaryAction() }
        content.addSubview(welcome)
        card.setFrameOrigin(.zero)
        finishStage.onOpen = { [weak self] in self?.primaryAction() }
        content.addSubview(finishStage)
        content.addSubview(card)
        stageCounter.frame = NSRect(x: 1107, y: M.windowSize.height - 44, width: 67, height: 26)
        stageCounter.font = OrbitOnboardingFonts.mono(16.58)
        stageCounter.alignment = .right
        stageCounter.textColor = BrandPalette.cobalt
        content.addSubview(stageCounter)
        progressTrack.frame = CGRect(x: 134, y: M.windowSize.height - 35, width: 943, height: 6.32)
        progressTrack.cornerRadius = 3.16
        progressTrack.backgroundColor = BrandPalette.ink.withAlphaComponent(0.13).cgColor
        progressFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressFill.backgroundColor = BrandPalette.cobalt.cgColor
        progressFill.cornerRadius = 3.16
        progressTrack.addSublayer(progressFill)
        let progressHost = NSView(frame: progressTrack.frame)
        progressTrack.frame = progressHost.bounds
        progressHost.wantsLayer = true
        progressHost.layer?.addSublayer(progressTrack)
        content.addSubview(progressHost)
        let grain = OrbitPaperGrainView(frame: content.bounds)
        grain.autoresizingMask = [.width, .height]
        content.addSubview(grain)
        window.contentView = content
        card.primaryButton.onPress = { [weak self] in self?.primaryAction() }
        card.backButton.onPress = { [weak self] in self?.backAction() }
        card.skipButton.onPress = { [weak self] in self?.skipAction() }
        applyTheme(theme)
        render(direction: .forward, animated: false)
        systemColors = NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSystemAccent() }
        }
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
        if flow.step == .welcome { welcome.play() }
        if intro == nil, flow.step == .finish {
            finishStage.play()
            let stage: NSView = finishStage
            OrbitOnboardingMotion.animate(stage.layer, key: "opacity", from: 0, to: 1, duration: 0.5, delay: 0.28)
            OrbitOnboardingMotion.animate(stage.layer, key: "transform.translation.x", from: 79, to: 0, duration: 0.5, delay: 0.28)
        }
        if let cover = OrbitOnboardingStartup.cover, cover !== self {
            cover.close()
            OrbitOnboardingStartup.cover = nil
        }
        NSApp.activate()
    }

    // MARK: Navigation

    var isTransitioning: Bool { busy || card.runningTransitions > 0 || welcomeTransitions > 0 }
    private var welcomeTransitions = 0
    private var finishStartedAt: CFTimeInterval?

    func primaryAction() {
        guard !isFinished, !isTransitioning, flow.canAdvance else { return }
        if flow.step == .importSource, flow.selectedSource != nil {
            busy = true
            Task { @MainActor in
                defer { busy = false }
                do {
                    flow.favourites = try await services.loadFavourites(flow)
                    advanceStep()
                } catch { showFailure(error) }
            }
            return
        }
        if flow.step == .defaultBrowser {
            busy = true
            if let source = flow.selectedSource {
                showImportProgress(.init(source: source.name))
                services.observeImportProgress { [weak self] in self?.showImportProgress($0) }
            }
            Task { @MainActor in
                defer { busy = false }
                if flow.defaultBrowserChoice == true {
                    await services.requestDefaultBrowser()
                    if let actual = services.isDefaultBrowser() { flow.defaultBrowserChoice = actual }
                }
                do {
                    flow.importDuration = try await services.prepareFinish(flow); flow.importApplied = true
                    flow.importSummary = services.importSummary()
                    advanceStep()
                    services.enteredFinish(flow)
                } catch { showFailure(error) }
            }
            return
        }
        switch flow.step {
        case .favourites:
            flow.favouritesSkipped = false
        case .sync:
            let enabled = flow.syncChoice == true
            Task { await services.setSync(enabled) }
        case .theme:
            guard let editor = themeEditor else { advanceStep(); return }
            busy = true
            Task { @MainActor in
                defer { busy = false }
                await editor.finishEditing()
                theme = editor.draft
                if !editor.isEdited, let target = themeTarget { try? await target.commit(editor.draft) }
                applyTheme(editor.draft)
                themeEditor = nil
                advanceStep()
            }
            return
        case .defaultBrowser:
            if flow.defaultBrowserChoice == true { Task { await services.requestDefaultBrowser() } }
        case .finish:
            isFinished = true
            closeThemeEditor()
            openBrowserPreview { [self] in services.finish(flow.record(.completed), self) }
            return
        default: break
        }
        advanceStep()
    }

    private func showFailure(_ error: Error) {
        render(direction: .forward, animated: false)
        if let configuration = activeSiteSessionConfiguration(), configuration.usesMockKeychain {
            BrowserImportUISynthetic.recordFailure(error, configuration: configuration)
        }
        let alert = NSAlert()
        alert.messageText = uiText("Could Not Complete Setup")
        alert.informativeText = uiText("Your data is kept. You can try again, or go back and skip the import.")
        alert.addButton(withTitle: uiText("OK"))
        if let window { alert.beginSheetModal(for: window) }
    }

    private func advanceStep() {
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
        if flow.step == .welcome {
            welcomeTransitions += 1
            render(direction: .backward, animated: false)
            welcome.play()
            card.isHidden = false
            OrbitOnboardingMotion.animate(card.layer, key: "opacity", from: 1, to: 0, duration: 0.3, outgoing: true)
            OrbitOnboardingMotion.animate(card.layer, key: "transform.translation.x", from: 0, to: 79, duration: 0.3, outgoing: true)
            OrbitOnboardingMotion.animate(welcome.layer, key: "opacity", from: 0, to: 1, duration: 0.5, delay: 0.28)
            OrbitOnboardingMotion.animate(welcome.layer, key: "transform.translation.x", from: -79, to: 0, duration: 0.5, delay: 0.28)
            DispatchQueue.main.asyncAfter(deadline: .now() + (OrbitMotionPreferences.prefersReducedMotion ? 0.25 : 0.8)) { [weak self] in
                guard let self else { return }
                card.isHidden = true
                card.layer?.removeAllAnimations()
                welcomeTransitions -= 1
            }
        } else { render(direction: .backward, animated: true) }
    }

    /// Theme step only: leaves the first Space's theme as it was before onboarding.
    func skipAction() {
        guard flow.hasSkip, !isTransitioning else { return }
        if flow.step == .importSource {
            flow.importChoice = BrowserOnboardingRecord.ImportChoice.none
            flow.selectedProfiles = []
            flow.favourites = BrowserOnboardingFavourite.starter
            advanceStep(); return
        }
        if flow.step == .favourites {
            flow.favouritesSkipped = true
            for i in flow.favourites.indices { flow.favourites[i].selected = false }
            advanceStep(); return
        }
        let editor = themeEditor
        busy = true
        Task { @MainActor in
            defer { busy = false }
            await editor?.finishEditing()
            themeEditor = nil
            applyTheme(originalTheme)
            if let target = themeTarget { try? await target.commit(originalTheme) }
            advanceStep()
        }
    }

    private func pushFromWelcome() {
        welcomeTransitions += 1
        render(direction: .forward, animated: false)
        welcome.isHidden = false
        OrbitOnboardingMotion.animate(welcome.layer, key: "opacity", from: 1, to: 0, duration: 0.3, outgoing: true)
        OrbitOnboardingMotion.animate(welcome.layer, key: "transform.translation.x", from: 0, to: -79, duration: 0.3, outgoing: true)
        OrbitOnboardingMotion.animate(card.layer, key: "opacity", from: 0, to: 1, duration: 0.5, delay: 0.28)
        OrbitOnboardingMotion.animate(card.layer, key: "transform.translation.x", from: 79, to: 0, duration: 0.5, delay: 0.28)
        card.playContents()
        DispatchQueue.main.asyncAfter(deadline: .now() + (OrbitMotionPreferences.prefersReducedMotion ? 0.25 : 1.1)) { [weak self] in
            self?.welcome.isHidden = true
            self?.welcome.layer?.removeAllAnimations()
            self?.welcomeTransitions -= 1
        }
    }

    /// Projects `flow` onto the window.
    func render(direction: OrbitOnboardingDirection, animated: Bool) {
        importProgressView?.removeFromSuperview(); importProgressView = nil
        card.textClip.isHidden = false; card.rightContent.isHidden = false
        updateTopBar()
        let isCard = flow.isCardStep
        welcome.isHidden = flow.step != .welcome
        finishStage.isHidden = flow.step != .finish
        card.isHidden = !isCard
        if flow.step == .finish {
            finishStage.update(flow: flow)
            finishStage.button.isEnabled = !services.waitsForBrowserPreview
            let start = { [weak self] in
                guard let self else { return }
                finishStage.isHidden = false
                finishStartedAt = CACurrentMediaTime(); finishStage.play()
            }
            if animated {
                card.isHidden = false
                start()
                OrbitOnboardingMotion.animate(card.layer, key: "opacity", from: 1, to: 0, duration: 0.3, outgoing: true)
                OrbitOnboardingMotion.animate(card.layer, key: "transform.translation.x", from: 0, to: -79, duration: 0.3, outgoing: true)
                OrbitOnboardingMotion.animate(finishStage.layer, key: "opacity", from: 0, to: 1, duration: 0.5, delay: 0.28)
                OrbitOnboardingMotion.animate(finishStage.layer, key: "transform.translation.x", from: 79, to: 0, duration: 0.5, delay: 0.28)
                DispatchQueue.main.asyncAfter(deadline: .now() + (OrbitMotionPreferences.prefersReducedMotion ? 0.25 : 0.8)) { [weak self] in
                    self?.card.isHidden = true
                    self?.card.layer?.removeAllAnimations()
                }
            } else { start() }
        }
        guard isCard else { return }
        card.primaryButton.title = flow.primaryTitle
        card.layoutControls(hasBack: flow.hasBack, hasSkip: flow.hasSkip, animated: animated)
        let (title, body, note) = text(for: flow.step)
        let page = OrbitOnboardingTextPage(title: title, body: body, note: note, hasBack: flow.hasBack)
        page.counter.stringValue = OrbitOnboardingText.counter(flow.index + 1)
        card.updateDots(index: flow.index, skipped: flow.skippedSteps.compactMap { OrbitOnboardingFlow.steps.firstIndex(of: $0) })
        choicesTop = (page.body.stringValue.isEmpty ? page.title.frame.maxY : page.body.frame.maxY) + 28.42
        if flow.step == .importSource {
            card.skipButton.title = OrbitOnboardingText.importNone
        } else { card.skipButton.title = OrbitOnboardingText.skip }
        card.skipButton.refresh()
        card.layoutControls(hasBack: flow.hasBack && flow.step != .importSource, hasSkip: flow.hasSkip && flow.step != .theme, animated: false)
        let right = makeRightPanel()
        card.show(page: page, right: right, direction: direction, animated: animated)
        refreshSelection()
        window?.recalculateKeyViewLoop()
    }

    private func updateTopBar() {
        let steps = flow.effectiveSteps
        let index = steps.firstIndex(of: flow.step) ?? flow.index
        stageCounter.attributedStringValue = BrandTextStyle.mono.attributedString(uiFormat("%d / %d", index + 1, steps.count), size: 16.58, attributes: [.foregroundColor: BrandPalette.cobalt, .kern: 1.658])
        stageCounter.isHidden = flow.step == .welcome
        progressTrack.isHidden = flow.step == .welcome
        let value = CGFloat(index) / CGFloat(max(1, steps.count - 1))
        guard lastProgressValue != value else { return }
        let previous = (progressFill.presentation() ?? progressFill).bounds.width
        let animated = lastProgressValue != nil && !OrbitMotionPreferences.prefersReducedMotion
        lastProgressValue = value
        let width = progressTrack.bounds.width * value
        CATransaction.begin(); CATransaction.setDisableActions(true)
        progressFill.frame = CGRect(x: 0, y: 0, width: width, height: progressTrack.bounds.height)
        CATransaction.commit()
        if animated {
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.width")
            animation.values = (0...60).map { previous + (width - previous) * (1 - pow(1 - Double($0) / 60, 2)) }
            animation.duration = 0.5; animation.timingFunction = CAMediaTimingFunction(name: .linear)
            progressFill.add(animation, forKey: "orbit.onboarding.progress")
        }
    }

    private func text(for step: BrowserOnboardingRecord.Step) -> (String, String, String?) {
        switch step {
        case .welcome, .importSource:
            return (OrbitOnboardingText.importTitle, "", nil)
        case .sync:
            let body = switch flow.syncAvailability {
            case .available: OrbitOnboardingText.syncBody
            case .signedOut: OrbitOnboardingText.syncSignedOut
            case .unavailable: OrbitOnboardingText.syncUnavailable
            }
            return (OrbitOnboardingText.syncTitle, flow.syncAvailability == .available ? "" : body, nil)
        case .favourites:
            return (OrbitOnboardingText.favouritesTitle, "", nil)
        case .theme: return (OrbitOnboardingText.themeTitle, "", nil)
        case .defaultBrowser: return (OrbitOnboardingText.defaultTitle, "", nil)
        case .finish:
            let importing = flow.importChoice.map { $0 != BrowserOnboardingRecord.ImportChoice.none } ?? false
            return (OrbitOnboardingText.finishTitle, importing ? OrbitOnboardingText.finishImportBody : OrbitOnboardingText.finishBody, nil)
        }
    }

    func showImportProgress(_ status: OrbitOnboardingImportStatus) {
        card.textClip.isHidden = true; card.rightContent.isHidden = true
        if importProgressView == nil {
            let view = OrbitOnboardingImportProgressView(frame: NSRect(origin: .zero, size: M.cardSize))
            card.addSubview(view)
            importProgressView = view
        }
        importProgressView?.update(status)
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
        selectionNote = nil
        switch flow.step {
        case .importSource: buildImportPanel(in: panel)
        case .sync:
            buildChoices(in: panel, yes: (OrbitOnboardingText.syncYesStrong, OrbitOnboardingText.syncYes),
                         no: (OrbitOnboardingText.syncNoStrong, OrbitOnboardingText.syncNo),
                         yesEnabled: flow.syncAvailability == .available,
                         select: { [weak self] value in self?.flow.selectSync(value) })
            let diagram = OrbitOnboardingSyncArt(frame: .zero)
            diagram.frame = NSRect(x: 811.58, y: 123.16, width: 347.37, height: 350.53)
            panel.addSubview(diagram)
            diagram.play()
            let note = NSTextField(labelWithString: "")
            note.font = OrbitOnboardingFonts.mono(16.58)
            note.textColor = BrandPalette.ink.withAlphaComponent(0.7)
            note.frame = NSRect(x: 54, y: choicesTop + 2 * M.choiceCardSize.height + M.optionGap + 19, width: 590, height: 26)
            panel.addSubview(note); selectionNote = note
        case .favourites:
            let grid = OrbitOnboardingFavouritesView(sites: flow.favourites)
            grid.frame.origin = NSPoint(x: 54, y: choicesTop - 3.16)
            let preview = miniPreview(in: panel, label: uiText("HOW IT LOOKS IN THE SIDEBAR"))
            grid.icons = Dictionary(uniqueKeysWithValues: flow.favourites.compactMap { site in services.cachedFavicon(site.url).map { (site.url, $0) } })
            preview.sites = flow.favourites
            preview.icons = grid.resolvedIcons
            for site in flow.favourites where grid.icons[site.url] == nil {
                Task { @MainActor [weak grid, weak preview, services] in
                    guard let icon = await services.favicon(site.url) else { return }
                    grid?.icons[site.url] = icon
                    preview?.icons[site.url] = icon
                }
            }
            grid.onToggle = { [weak self] index in
                guard let self, !isTransitioning else { return }
                flow.favouritesSkipped = false
                flow.favourites[index].selected.toggle()
                favouritesView?.update(sites: flow.favourites)
                preview.sites = flow.favourites
                card.page?.note.stringValue = OrbitOnboardingText.favouriteHint(flow.selectedFavourites.count)
                services.persist(flow.record(.started))
            }
            favouritesView = grid
            panel.addSubview(grid)
        case .theme: buildThemePanel(in: panel)
        case .defaultBrowser:
            buildChoices(in: panel, yes: (OrbitOnboardingText.defaultYesStrong, OrbitOnboardingText.defaultYes),
                         no: (OrbitOnboardingText.defaultNoStrong, OrbitOnboardingText.defaultNo), yesEnabled: true,
                         select: { [weak self] value in self?.flow.defaultBrowserChoice = value; self?.refreshPromptOpacity() })
            let art = OrbitOnboardingDefaultArt(frame: NSRect(x: 868.42, y: 173.68, width: 268.42, height: 249.47))
            panel.addSubview(art); art.play()

        case .welcome, .finish: break
        }
        return panel
    }

    private func refreshPromptOpacity() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OrbitMotionPreferences.prefersReducedMotion ? 0.25 : 0.3
            promptMock?.animator().alphaValue = flow.defaultBrowserChoice == false ? 0.25 : 0.55
        }
    }

    private func buildChoices(in panel: NSView, yes: (String, String), no: (String, String), yesEnabled: Bool,
                              select: @escaping (Bool) -> Void) {
        let size = M.choiceCardSize
        let top = choicesTop
        for (index, (strong, detail)) in [yes, no].enumerated() {
            let card = OrbitOnboardingChoiceCard(strong: strong, detail: detail)
            card.setFrameOrigin(NSPoint(x: 54, y: top + CGFloat(index) * (size.height + M.optionGap)))
            card.isEnabled = index == 1 || yesEnabled
            card.onSelect = { [weak self] in
                guard let self, !isTransitioning else { return }
                select(index == 0)
                refreshSelection()
            }
            panel.addSubview(card)
            optionCards.append(card)
        }
    }

    private func miniPreview(in panel: NSView, label: String) -> OrbitOnboardingMiniPreview {
        let heading = NSTextField(labelWithString: label)
        heading.attributedStringValue = BrandTextStyle.mono.attributedString(label, size: 16.58, attributes: [.foregroundColor: BrandPalette.cobalt, .kern: 1.99])
        heading.frame = NSRect(x: 780, y: 132.63, width: 366.32, height: 25)
        panel.addSubview(heading)
        let preview = OrbitOnboardingMiniPreview(frame: NSRect(x: 780, y: 166.26, width: 366.32, height: 236.84))
        preview.wantsLayer = true
        preview.layer?.shadowColor = BrandPalette.ink.cgColor
        preview.layer?.shadowOpacity = 0.67
        preview.layer?.shadowRadius = 17.37
        preview.layer?.shadowOffset = CGSize(width: 0, height: 22.11)
        preview.layer?.shadowPath = CGPath(roundedRect: preview.bounds.insetBy(dx: 25.26, dy: 25.26), cornerWidth: 17.37, cornerHeight: 17.37, transform: nil)
        panel.addSubview(preview)
        return preview
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
        let art = OrbitOnboardingTrajectoryArt(frame: .zero)
        art.frame = NSRect(x: 751.58, y: 135.79, width: 426.32, height: 309.02)
        panel.addSubview(art)
        art.play()
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
        let x: CGFloat = 54
        var y = choicesTop - 3.16
        var cards: [OrbitOnboardingOptionCard] = []
        for (index, source) in flow.sources.enumerated() {
            let (icon, tint) = services.sourceArtwork(source)
            let row = OrbitOnboardingBrowserRow(title: source.profiles.isEmpty ? source.name : source.name + "\n" + uiFormat("%d profiles", source.profiles.count), icon: icon, tint: tint)
            row.setFrameOrigin(NSPoint(x: x + CGFloat(index % 2) * (rowSize.width + 12.63), y: choicesTop - 3.16 + CGFloat(index / 2) * (rowSize.height + 12.63)))
            row.onSelect = { [weak self] in
                guard let self, !isTransitioning, flow.selectedSource != source else { return }
                flow.select(source: source)
                layoutImportRows()
                refreshSelection()
            }
            document.addSubview(row)
            cards.append(row)
        }
        y = choicesTop - 3.16 + CGFloat((flow.sources.count + 1) / 2) * (rowSize.height + 12.63)
        if let source = flow.selectedSource, !source.profiles.isEmpty {
            let list = OrbitOnboardingProfileList(profiles: source.profiles, width: 554)
            list.setFrameOrigin(NSPoint(x: x, y: y))
            list.onSelect = { [weak self] directory in
                guard let self, !isTransitioning else { return }
                flow.select(profile: directory, of: source); refreshSelection()
            }
            document.addSubview(list); profileList = list
            y += list.frame.height + 14
        }
        let scope = NSTextField(wrappingLabelWithString: uiText("Spaces · pinned tabs · themes\nBoosts · passwords (encrypted)"))
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 26.53; style.maximumLineHeight = 26.53
        scope.attributedStringValue = BrandTextStyle.mono.attributedString(scope.stringValue, size: 16.58, attributes: [.foregroundColor: BrandPalette.ink.withAlphaComponent(0.75), .kern: 0.663, .paragraphStyle: style])
        scope.frame = NSRect(x: x - 2, y: y + 9.48, width: 591.37, height: 56); document.addSubview(scope)
        y += 66
        optionCards = cards
        document.setFrameSize(NSSize(width: document.frame.width, height: max(y, M.importViewportBottom)))
        window?.recalculateKeyViewLoop()
    }

    private func buildThemePanel(in panel: NSView) {
        guard let target = themeTarget else { return }
        let editor = OrbitThemeEditorController(spaceID: target.spaceID, profileID: target.profileID, stored: theme,
                                                initial: theme ?? BrandPalette.spaceGradients[0].theme(),
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
        let scaled = OrbitOnboardingFlippedView(frame: NSRect(x: 800,
                                                             y: 125,
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
        scaled.isHidden = true
        panel.addSubview(scaled)
        let preview = miniPreview(in: panel, label: uiText("YOUR FIRST SPACE"))
        preview.sites = flow.favourites
        preview.icons = Dictionary(uniqueKeysWithValues: flow.favourites.compactMap { site in services.cachedFavicon(site.url).map { (site.url, $0) } })
        for site in flow.favourites where preview.icons[site.url] == nil {
            Task { @MainActor [weak preview, services] in
                if let icon = await services.favicon(site.url) { preview?.icons[site.url] = icon }
            }
        }
        let colorName = NSTextField(labelWithString: uiText("Mandarine").uppercased())
        colorName.font = OrbitOnboardingFonts.mono(16.58); colorName.textColor = BrandPalette.ink
        colorName.frame = NSRect(x: 54, y: choicesTop + 104.21, width: 530, height: 22)
        colorName.attributedStringValue = BrandTextStyle.mono.attributedString(colorName.stringValue, size: 16.58, attributes: [.foregroundColor: BrandPalette.ink, .kern: 1.658])
        panel.addSubview(colorName)
        for (index, preset) in BrandPalette.spaceGradients.enumerated() {
            let button = OrbitOnboardingPlanetButton(index: index)
            button.frame = NSRect(x: 42.95 + CGFloat(index) * 104.21, y: choicesTop - 7.89, width: 101.05, height: 101.05)
            button.isSelectedPlanet = (theme?.presetID ?? "brand.coral") == "brand." + preset.id
            button.onPress = { [weak self, weak editor, weak preview, weak panel] in
                guard let self, let editor else { return }
                let state = OrbitThemeEditorState(theme: preset.theme())
                editor.view.state = state; editor.view.onChange?(state)
                preview?.planetIndex = index
                colorName.attributedStringValue = BrandTextStyle.mono.attributedString(uiText(["Mandarine", "Cobalt", "Soleil", "Aurore"][index]).uppercased(), size: 16.58, attributes: [.foregroundColor: BrandPalette.ink, .kern: 1.658])
                panel?.subviews.compactMap { $0 as? OrbitOnboardingPlanetButton }.forEach { $0.isSelectedPlanet = $0.planetIndex == index }
                self.applyTheme(preset.theme())
            }
            panel.addSubview(button)
        }
        for button in panel.subviews.compactMap({ $0 as? OrbitOnboardingPlanetButton }) {
            button.onCustomize = { [weak scaled, weak preview] in
                scaled?.isHidden.toggle(); preview?.isHidden = scaled?.isHidden == false
            }
        }

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
            profileList?.selectedProfiles = flow.selectedProfiles
        case .sync:
            selectionNote?.attributedStringValue = BrandTextStyle.mono.attributedString((flow.syncChoice == true ? uiText("synced to your iCloud") : uiText("nothing uploaded")).uppercased(), size: 16.58, attributes: [.foregroundColor: BrandPalette.ink.withAlphaComponent(0.7), .kern: 0.995])
            for (index, card) in optionCards.enumerated() { card.isSelected = flow.syncChoice == (index == 0) }
            card.rightView?.subviews.compactMap { $0 as? OrbitOnboardingSyncArt }.first?.select(flow.syncChoice == true)
        case .defaultBrowser:
            for (index, card) in optionCards.enumerated() { card.isSelected = flow.defaultBrowserChoice == (index == 0) }
        default: break
        }
        for card in optionCards { card.accent = flow.step == .importSource ? BrandPalette.coral : accent }
        profileList?.accent = accent
        card.primaryButton.isEnabled = flow.canAdvance
        updateTopBar()
    }

    /// Instant recolour of the backdrop, panel tint and accent controls (one frame).
    func applyTheme(_ newTheme: BrowserSpaceTheme?) {
        let themed = newTheme.map { !($0.colors.isEmpty && $0.presetID == BrowserSpaceThemePresets.defaultID) } ?? false
        theme = newTheme
        accent = OrbitOnboardingColors.accent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.apply(theme: themed ? newTheme : nil)
        card.applyAccent(accent, themed: themed)
        for card in optionCards { card.accent = flow.step == .importSource ? BrandPalette.coral : accent }
        profileList?.accent = accent
        CATransaction.commit()
    }

    /// Hosts the real first window's content; changing frames lays text out at its native size.
    func stageBrowserWindow(_ browser: NSWindow) {
        guard flow.step == .finish, previewContent == nil, let root = window?.contentView, let content = browser.contentView else { return }
        previewWindow = browser; previewContent = content
        finishStage.button.isEnabled = true
        browser.contentView = NSView()
        root.layer?.masksToBounds = true
        content.autoresizingMask = []
        content.frame = NSRect(x: 110, y: -680, width: 980, height: 750)
        root.addSubview(content)
        content.layoutSubtreeIfNeeded()
        OrbitOnboardingMotion.entrance(content, y: 220, duration: 1.6, delay: max(0, 0.9 - (CACurrentMediaTime() - (finishStartedAt ?? CACurrentMediaTime()))))
    }

    private func openBrowserPreview(completion: @escaping @MainActor () -> Void) {
        guard let content = previewContent, let root = window?.contentView else { completion(); return }
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        OrbitOnboardingMotion.animate(finishStage.layer, key: "opacity", from: 1, to: 0, duration: 0.45, outgoing: true)
        OrbitOnboardingMotion.animate(finishStage.layer, key: "transform.translation.y", from: 0, to: 24, duration: 0.45, outgoing: true)
        finishStage.layer?.opacity = 0
        OrbitOnboardingMotion.animate(background.glow, key: "opacity", from: 1, to: 0, duration: 0.8, delay: 0.3)
        background.glow.opacity = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduced ? 0 : 0.15)) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduced ? 0.25 : 1.3
                context.timingFunction = OrbitOnboardingMotion.curve
                context.allowsImplicitAnimation = true
                if reduced {
                    content.frame = root.bounds; content.alphaValue = 0
                    content.animator().alphaValue = 1
                } else { content.animator().frame = root.bounds }
            } completionHandler: { MainActor.assumeIsolated { completion() } }
        }
    }

    func releaseBrowserPreview() {
        guard let content = previewContent, let browser = previewWindow else { return }
        content.removeFromSuperview()
        browser.contentView = content
        content.frame = browser.contentView?.superview?.bounds ?? content.frame
        content.autoresizingMask = [.width, .height]
        previewContent = nil; previewWindow = nil
    }

    private func refreshSystemAccent() {
        applyTheme(theme)
        finishStage.button.accent = BrandPalette.controlAccent
        themeEditor?.view.render()
        favouritesView?.update(sites: flow.favourites)
        (promptMock as? OrbitOnboardingPromptMock)?.refreshAccent()
        card.updateDots(index: flow.index, skipped: flow.skippedSteps.compactMap { OrbitOnboardingFlow.steps.firstIndex(of: $0) })
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
