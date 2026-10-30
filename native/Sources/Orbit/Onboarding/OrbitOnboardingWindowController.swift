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
        let content = NSView(frame: NSRect(origin: .zero, size: M.windowSize))
        content.wantsLayer = true
        background.autoresizingMask = [.width, .height]
        content.addSubview(background)
        welcome.autoresizingMask = [.width, .height]
        welcome.onContinue = { [weak self] in self?.primaryAction() }
        content.addSubview(welcome)
        card.setFrameOrigin(NSPoint(x: 120, y: 95))
        finishStage.onOpen = { [weak self] in self?.primaryAction() }
        content.addSubview(finishStage)
        content.addSubview(card)
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
            OrbitOnboardingMotion.animate(card.layer, key: "opacity", from: 1, to: 0, duration: 0.55, outgoing: true)
            OrbitOnboardingMotion.animate(card.layer, key: "transform.translation.y", from: 0, to: 40, duration: 0.55, outgoing: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + (OrbitMotionPreferences.prefersReducedMotion ? 0.25 : 0.55)) { [weak self] in
                guard let self else { return }
                card.layer?.removeAllAnimations()
                render(direction: .backward, animated: false); welcome.play()
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
        render(direction: .forward, animated: false)
        welcome.isHidden = false
        welcomeTransitions += 1
        OrbitOnboardingMotion.animate(welcome.layer, key: "opacity", from: 1, to: 0, duration: 0.5, outgoing: true)
        OrbitOnboardingMotion.animate(welcome.layer, key: "transform.translation.y", from: 0, to: 30, duration: 0.5, outgoing: true)
        OrbitOnboardingMotion.entrance(card, y: 60, duration: 1, delay: 0.25)
        OrbitOnboardingMotion.animate(card.layer, key: "transform.scale", from: 0.96, to: 1, duration: 1, delay: 0.25)
        DispatchQueue.main.asyncAfter(deadline: .now() + (OrbitMotionPreferences.prefersReducedMotion ? 0.25 : 1.25)) { [weak self] in
            self?.welcome.isHidden = true
            self?.welcome.layer?.removeAllAnimations()
            self?.welcomeTransitions -= 1
        }
    }

    /// Projects `flow` onto the window.
    func render(direction: OrbitOnboardingDirection, animated: Bool) {
        let isCard = flow.isCardStep
        welcome.isHidden = flow.step != .welcome
        finishStage.isHidden = flow.step != .finish
        card.isHidden = !isCard
        if flow.step == .finish {
            finishStage.update(flow: flow)
            finishStage.button.isEnabled = !services.waitsForBrowserPreview
            let start = { [weak self] in
                guard let self else { return }
                card.isHidden = true; finishStage.isHidden = false
                finishStartedAt = CACurrentMediaTime(); finishStage.play()
            }
            if animated {
                card.isHidden = false; finishStage.isHidden = true
                OrbitOnboardingMotion.animate(card.layer, key: "opacity", from: 1, to: 0, duration: 0.55, outgoing: true)
                OrbitOnboardingMotion.animate(card.layer, key: "transform.translation.y", from: 0, to: 40, duration: 0.55, outgoing: true)
                OrbitOnboardingMotion.animate(card.layer, key: "transform.scale", from: 1, to: 0.97, duration: 0.55, outgoing: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + (OrbitMotionPreferences.prefersReducedMotion ? 0.25 : 0.55), execute: start)
            } else { start() }
        }
        guard isCard else { return }
        card.layoutControls(hasBack: flow.hasBack, hasSkip: flow.hasSkip, animated: animated)
        card.primaryButton.title = flow.primaryTitle
        let (title, body, note) = text(for: flow.step)
        let page = OrbitOnboardingTextPage(title: title, body: body, note: note, hasBack: flow.hasBack)
        page.counter.stringValue = OrbitOnboardingText.counter(flow.index + 1)
        card.updateDots(index: flow.index, skipped: flow.skippedSteps.compactMap { OrbitOnboardingFlow.steps.firstIndex(of: $0) })
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
        case .favourites:
            return (OrbitOnboardingText.favouritesTitle, flow.selectedSource == nil ? OrbitOnboardingText.favouritesBody : OrbitOnboardingText.favouritesImportedBody, OrbitOnboardingText.favouriteHint(flow.selectedFavourites.count))
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
            let diagram = OrbitOnboardingSyncDiagram(frame: NSRect(x: 89, y: 324, width: 402, height: 70))
            panel.addSubview(diagram)
            let hint = NSTextField(wrappingLabelWithString: uiText("Spaces · pinned tabs · themes · Boosts · passwords (encrypted)"))
            hint.font = OrbitOnboardingFonts.mono(11); hint.textColor = BrandPalette.ink3; hint.alignment = .center
            hint.frame = NSRect(x: 34, y: 408, width: 512, height: 38); panel.addSubview(hint)
        case .favourites:
            let grid = OrbitOnboardingFavouritesView(sites: flow.favourites)
            grid.frame.origin = NSPoint(x: 34, y: 131)
            grid.onToggle = { [weak self] index in
                guard let self, !isTransitioning else { return }
                flow.favouritesSkipped = false
                flow.favourites[index].selected.toggle()
                favouritesView?.update(sites: flow.favourites)
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
            let mock = OrbitOnboardingPromptMock(frame: NSRect(x: 140, y: 278, width: 300, height: 220))
            mock.alphaValue = flow.defaultBrowserChoice == false ? 0.25 : 0.55
            promptMock = mock
            panel.addSubview(mock)
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
        let top: CGFloat = flow.step == .defaultBrowser ? 95 : 150
        for (index, (strong, detail)) in [yes, no].enumerated() {
            let card = OrbitOnboardingChoiceCard(strong: strong, detail: detail)
            card.setFrameOrigin(NSPoint(x: panelCenterX - size.width / 2, y: top + CGFloat(index) * (size.height + M.optionGap)))
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
            let row = OrbitOnboardingBrowserRow(title: source.name + "\n" + uiFormat("%d profiles", source.profiles.count), icon: icon, tint: tint)
            row.setFrameOrigin(NSPoint(x: x, y: y))
            row.onSelect = { [weak self] in
                guard let self, !isTransitioning, flow.selectedSource != source else { return }
                flow.select(source: source)
                layoutImportRows()
                refreshSelection()
            }
            document.addSubview(row)
            cards.append(row)
            y += rowSize.height
            if flow.selectedSource == source, !source.profiles.isEmpty {
                y += M.profileListGap
                let list = OrbitOnboardingProfileList(profiles: source.profiles, width: rowSize.width - 2 * M.profileListInset)
                list.setFrameOrigin(NSPoint(x: x + M.profileListInset, y: y))
                list.onSelect = { [weak self] directory in
                    guard let self, !isTransitioning else { return }
                    flow.select(profile: directory, of: source)
                    refreshSelection()
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
            guard let self, !isTransitioning else { return }
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
                                                initial: theme ?? BrandPalette.spaceGradients[0].theme(),
                                                commit: target.commit, replay: { _ in })
        editor.view.scopedPresets = BrandPalette.spaceGradients.map { preset in
            OrbitThemeEditorPreset(title: uiText(preset.name), theme: preset.theme(),
                colors: preset.stops.map(OrbitSpaceThemes.color), locations: preset.locations.map { NSNumber(value: $0) })
        }
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
            profileList?.selectedProfiles = flow.selectedProfiles
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
        accent = OrbitOnboardingColors.accent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.apply(theme: themed ? newTheme : nil)
        card.applyAccent(accent, themed: themed)
        for card in optionCards { card.accent = accent }
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
