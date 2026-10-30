import AppKit
import BrowserShell
import BrowserEngine
import BrowserCore
import SwiftUI
@preconcurrency import Translation

@MainActor
final class BrowserPageTranslation: ObservableObject {
    weak var surface: (any BrowserEngineSurface)?
    let generation: UInt64
    var state = BrowserTranslationState()
    var onChange: (() -> Void)?
    @Published var configuration: TranslationSession.Configuration?
    var host: NSView?
    var detection: Task<Void, Never>?
    private var revision = 0
    private var targetRevision = 0
    private(set) var targets: [String] = []
    private var privateWindow = false
    private var usesHighFidelity = false
    private(set) var failure: (stage: String, domain: String, code: Int)?

    init(surface: any BrowserEngineSurface) { self.surface = surface; generation = surface.documentGeneration }
    var isCurrent: Bool { surface.map { !$0.isDisposed && $0.documentGeneration == generation } ?? false }

    private func languageAvailability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: usesHighFidelity ? .highFidelity : .lowLatency) }
        return LanguageAvailability()
    }

    func detect(privateWindow: Bool, preferred: [String] = Locale.preferredLanguages) {
        self.privateWindow = privateWindow
        detection = Task { [weak self] in
            guard let self, let surface else { return }
            do {
                let sample = try await surface.translationSample()
                let language = BrowserTranslationState.detectLanguage(text: sample.text, hint: sample.language)
                guard let source = language, let target = preferred.first else { return }
                var availability = await languageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
                if #available(macOS 26.4, *), availability != .installed {
                    let installed = await LanguageAvailability(preferredStrategy: .highFidelity).status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
                    if installed == .installed { usesHighFidelity = true; availability = installed }
                }
                guard isCurrent, !Task.isCancelled else { return }
                state.detect(source: source, preferred: preferred,
                             supported: availability == .installed || (!privateWindow && availability == .supported))
                onChange?()
                await loadTargets()
            } catch { /* A navigation or unsupported document has no offer. */ }
        }
    }

    /// The service is authoritative; private documents expose installed pairs only.
    private func strategy(for target: String) async -> Bool? {
        let source = Locale.Language(identifier: state.source)
        let target = Locale.Language(identifier: target)
        let classic: LanguageAvailability
        if #available(macOS 26.4, *) { classic = LanguageAvailability(preferredStrategy: .lowLatency) }
        else { classic = LanguageAvailability() }
        let status = await classic.status(from: source, to: target)
        if status == .installed { return false }
        if #available(macOS 26.4, *) {
            let high = await LanguageAvailability(preferredStrategy: .highFidelity).status(from: source, to: target)
            if high == .installed || (!privateWindow && status == .unsupported && high == .supported) { return true }
        }
        return !privateWindow && status == .supported ? false : nil
    }

    func loadTargets() async {
        var languages = await languageAvailability().supportedLanguages
        if #available(macOS 26.4, *) {
            languages += await LanguageAvailability(preferredStrategy: .highFidelity).supportedLanguages
        }
        var supported: [String] = []
        for language in languages {
            guard isCurrent, !Task.isCancelled else { return }
            let identifier = language.minimalIdentifier
            if !supported.contains(identifier), await strategy(for: identifier) != nil { supported.append(identifier) }
        }
        guard isCurrent, !Task.isCancelled else { return }
        targets = supported.sorted {
            Self.languageName($0).localizedStandardCompare(Self.languageName($1)) == .orderedAscending
        }
        onChange?()
    }

    static func languageName(_ identifier: String) -> String {
        // Language names are supplied and localized by Foundation, not English lookup keys.
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    func chooseTarget(_ target: String, in root: NSView) async {
        targetRevision += 1
        let selection = targetRevision
        guard targets.contains(target), let highFidelity = await strategy(for: target),
              isCurrent, targetRevision == selection else { return }
        // Restore originals before changing models; translated text must never become the source.
        await restore(cancelTargetSelection: false)
        guard isCurrent, targetRevision == selection, state.phase != .failed,
              state.selectTarget(target, supported: true) else { return }
        usesHighFidelity = highFidelity
        begin(in: root)
    }

    func begin(in root: NSView) {
        guard isCurrent, state.begin() else { return }
        targetRevision += 1
        revision += 1
        if host == nil {
            let view = NSHostingView(rootView: TranslationTaskView(model: self))
            view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            root.addSubview(view)
            host = view
        }
        if #available(macOS 26.4, *) {
            configuration = .init(source: Locale.Language(identifier: state.source), target: Locale.Language(identifier: state.target), preferredStrategy: usesHighFidelity ? .highFidelity : .lowLatency)
        } else {
            configuration = .init(source: Locale.Language(identifier: state.source), target: Locale.Language(identifier: state.target))
        }
        onChange?()
    }

    func translate(using session: TranslationSession) async {
        guard let surface, isCurrent, state.phase == .translating else { return }
        let request = revision
        var stage = "availability"
        do {
            if privateWindow {
                let availability = await languageAvailability().status(from: Locale.Language(identifier: state.source), to: Locale.Language(identifier: state.target))
                guard availability == .installed else { throw CancellationError() }
            }
            var settling = true
            while isCurrent, revision == request {
                try Task.checkCancellation()
                stage = "extract"
                let texts = try await surface.translationTexts()
                guard isCurrent, revision == request else { return }
                if texts.isEmpty {
                    if settling { state.complete(); onChange?(); settling = false }
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                stage = "translate"
                let responses = try await translateBatch(texts, using: session)
                try Task.checkCancellation()
                guard isCurrent, revision == request else { return }
                stage = "apply"
                try await surface.applyTranslation(responses)
            }
        } catch {
            guard isCurrent, revision == request else { return }
            let error = error as NSError
            failure = (stage, error.domain, error.code)
            // Roll back partial batches before reporting failure; the original remains available.
            try? await surface.restoreTranslation()
            guard isCurrent, revision == request else { return }
            state.fail(); configuration = nil; onChange?()
        }
    }

    private func translateBatch(_ texts: [BrowserTranslationText], using session: TranslationSession) async throws -> [BrowserTranslationText] {
        do {
            let responses = try await session.translations(from: Self.requests(texts))
            return responses.compactMap { response in
                response.clientIdentifier.map { BrowserTranslationText(id: $0, text: response.targetText) }
            }
        } catch {
            try Task.checkCancellation()
            if texts.count > 1, TranslationError.internalError ~= error || TranslationError.nothingToTranslate ~= error {
                let middle = texts.count / 2
                let first = try await translateBatch(Array(texts[..<middle]), using: session)
                return first + (try await translateBatch(Array(texts[middle...]), using: session))
            }
            if texts.count == 1, TranslationError.nothingToTranslate ~= error { return texts }
            throw error
        }
    }

    private nonisolated static func requests(_ texts: [BrowserTranslationText]) -> sending [TranslationSession.Request] {
        texts.map { TranslationSession.Request(sourceText: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), clientIdentifier: $0.id) }
    }

    func restore(cancelTargetSelection: Bool = true) async {
        guard let surface, isCurrent else { return }
        if cancelTargetSelection { targetRevision += 1 }
        revision += 1
        let request = revision
        configuration = nil
        do {
            try await surface.restoreTranslation()
            guard isCurrent, revision == request else { return }
            state.restore()
        } catch { if isCurrent, revision == request { state.fail() } }
        onChange?()
    }

    func retire() {
        targetRevision += 1
        revision += 1
        detection?.cancel(); detection = nil
        configuration = nil
        host?.removeFromSuperview(); host = nil
        onChange = nil
    }
}

private struct TranslationTaskView: View {
    @ObservedObject var model: BrowserPageTranslation
    var body: some View {
        Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
            .translationTask(model.configuration) { session in await model.translate(using: session) }
    }
}

/// Shared within one environment so translation follows live documents across window owners.
@MainActor
final class BrowserTranslationPages {
    var pages: [ObjectIdentifier: BrowserPageTranslation] = [:]

    func prune() {
        for (key, page) in pages where !page.isCurrent {
            page.retire(); pages.removeValue(forKey: key)
        }
    }

    func close() {
        for page in pages.values { page.retire() }
        pages.removeAll()
    }
}

@MainActor
final class BrowserTranslationController<Engine: BrowserEngine> {
    weak var owner: BrowserWindowController<Engine>?
    private var pages: [ObjectIdentifier: BrowserPageTranslation] {
        get { owner?.translationPages.pages ?? [:] }
        set { owner?.translationPages.pages = newValue }
    }
    let popover = OrbitFrostPopover()
    var preferences = try! BrowserSitePreferenceStore()
    var onPreferenceError: ((any Error) -> Void)?
    private(set) var optionsMenu: BrowserTranslationOptionsMenu?
    private var presentedPage: BrowserPageTranslation?
    init(owner: BrowserWindowController<Engine>) {
        self.owner = owner
        popover.behavior = .transient
        popover.animates = false
        owner.addressField.onStatusPress = { [weak self] in self?.show() }
        owner.addressField.statusForSpace = { [weak self] _ in self?.status }
    }
    var page: BrowserPageTranslation? { owner?.session.selectedSurface.flatMap { pages[ObjectIdentifier($0)] } }
    var status: String? {
        switch page?.state.phase {
        case .available, .original: uiText("Translation Available")
        case .translating: uiText("Translating…")
        case .translated: uiText("Translated")
        case .failed: uiText("Translation unavailable")
        default: nil
        }
    }
    func render() {
        guard let owner else { return }
        owner.translationPages.prune()
        for surface in owner.session.ownedSurfaces {
            guard let page = pages[ObjectIdentifier(surface)] else { continue }
            page.onChange = { [weak self] in self?.update() }
            if let host = page.host, let root = owner.window?.contentView, host.superview !== root {
                root.addSubview(host)
            }
        }
        if let surface = owner.session.selectedSurface, surface.supportsPageTranslation,
           !surface.navigationState.isLoading, ["https", "http"].contains(surface.navigationState.committedURL?.scheme),
           pages[ObjectIdentifier(surface)] == nil {
            let page = BrowserPageTranslation(surface: surface)
            pages[ObjectIdentifier(surface)] = page
            page.onChange = { [weak self] in self?.update() }
            page.detect(privateWindow: owner.isPrivateWindow)
        }
        for surface in owner.session.ownedSurfaces {
            pages[ObjectIdentifier(surface)]?.state.suppressSite(preferences.preferences(
                url: surface.navigationState.committedURL, profileID: surface.profileID).neverTranslate)
        }
        update()
    }
    private func update() {
        owner?.addressField.setStatus(status)
        owner?.addressField.setAccessibilityHelp(status)
        owner?.addressField.setAccessibilityCustomActions(status == nil ? [] : [
            NSAccessibilityCustomAction(name: uiText("Translate")) { [weak self] in self?.show(); return true }
        ])
        if popover.isShown, presentedPage !== page { optionsMenu?.cancelTracking(); popover.close() }
    }
    func show() {
        guard let owner, let page, page.isCurrent, page.state.phase != .unavailable else { return }
        if popover.isShown { popover.close(); return }
        presentedPage = page
        let view = BrowserTranslationPopover(state: page.state, options: { [weak self] button in
            self?.showOptions(from: button)
        }) { [weak self, weak page, weak owner] in
            guard let self, let page, let owner, self.page === page, page.isCurrent else { return }
            popover.close()
            if page.state.phase == .translated { Task { await page.restore() } }
            else if let root = owner.window?.contentView { page.begin(in: root) }
        }
        let controller = NSViewController(); controller.view = view
        popover.contentViewController = controller
        popover.contentSize = view.frame.size
        let anchor = owner.sidebar.addressContainer
        var rect = owner.addressField.convert(owner.addressField.statusAnchorRect, to: anchor)
        rect.origin.y = anchor.isFlipped ? anchor.bounds.maxY - 4 : anchor.bounds.minY
        rect.size.height = 1
        popover.show(relativeTo: rect, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }
    func makeOptionsMenu() -> BrowserTranslationOptionsMenu? {
        guard let owner, let page, page.isCurrent, let surface = owner.session.selectedSurface else { return nil }
        let url = surface.navigationState.committedURL, profile = surface.profileID
        let suppressed = preferences.preferences(url: url, profileID: profile).neverTranslate
        return BrowserTranslationOptionsMenu(targets: page.targets, suppressed: suppressed, choose: { [weak self, weak page] target in
            guard let self, let page, self.page === page, page.isCurrent, let root = self.owner?.window?.contentView else { return }
            self.popover.close()
            Task { await page.chooseTarget(target, in: root) }
        }, toggleSite: { [weak self, weak page] in
            guard let self, let page, self.page === page, page.isCurrent else { return }
            var value = self.preferences.preferences(url: url, profileID: profile)
            value.neverTranslate.toggle()
            do {
                try self.preferences.set(value, url: url, profileID: profile)
                for document in self.pages.values where document.surface?.profileID == profile
                    && BrowserSitePreferenceStore.host(document.surface?.navigationState.committedURL) == BrowserSitePreferenceStore.host(url) {
                    document.state.suppressSite(value.neverTranslate)
                    document.onChange?()
                    if value.neverTranslate { Task { await document.restore() } }
                }
                self.popover.close()
                self.update()
            } catch { self.onPreferenceError?(error) }
        }, settings: { [weak self, weak page] in
            guard let self, let page, self.page === page, page.isCurrent, let owner = self.owner else { return }
            self.popover.close()
            owner.openTab(url: URL(string: "chrome://settings/languages")!)
        })
    }

    private func showOptions(from button: NSButton) {
        guard let menu = makeOptionsMenu(), let sourceWindow = button.window,
              let root = owner?.window?.contentView, let destinationWindow = root.window else { return }
        let screen = sourceWindow.convertPoint(toScreen: button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        let point = root.convert(destinationWindow.convertPoint(fromScreen: screen), from: nil)
        optionsMenu = menu
        popover.close()
        menu.popUp(positioning: nil, at: point, in: root)
        optionsMenu = nil
    }

    func close() {
        optionsMenu?.cancelTracking()
        popover.close()
        // A released surface belongs to its receiver or the rescue holder, even if this
        // window closes while adoption is pending. Only retire documents still owned here.
        for surface in owner?.session.ownedSurfaces ?? [] {
            pages.removeValue(forKey: ObjectIdentifier(surface))?.retire()
        }
    }
}

/// 236 pt content width, 32 pt language badge, 104 × 32 pt actions and 10 pt insets.
@MainActor
final class BrowserTranslationPopover: NSView {
    let primary: NSButton
    let options: NSButton
    init(state: BrowserTranslationState, options onOptions: @escaping (NSButton) -> Void = { _ in }, action: @escaping () -> Void) {
        let translated = state.phase == .translated
        primary = TranslationActionButton(translated ? uiText("Use Original") : uiText("Translate"), identifier: "translation-primary", onPress: action)
        options = TranslationActionButton(uiText("Options"), identifier: "translation-options", onPress: {})
        super.init(frame: NSRect(x: 0, y: 0, width: 236, height: translated ? 100 : 102))
        (options as? TranslationActionButton)?.onPress = { [weak options] in
            if let options { onOptions(options) }
        }
        (options as? TranslationActionButton)?.secondary = true
        let badge = NSView()
        let badgeLabel = NSTextField(labelWithString: uiText("Aa"))
        badgeLabel.frame = NSRect(x: 0, y: 6, width: 32, height: 20)
        badge.addSubview(badgeLabel)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .center; badgeLabel.font = BrandTextStyle.ui.font(size: 14, weight: .semibold)
        badge.wantsLayer = true; badge.layer?.cornerRadius = 16
        badge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        let locale = Locale.current
        let language = locale.localizedString(forLanguageCode: translated ? state.source : state.target) ?? (translated ? state.source : state.target)
        let message = translated ? uiFormat("Translated from %@.", language) : uiFormat("Translate this page\nto %@?", language)
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = BrandTextStyle.ui.font(size: 14); label.textColor = .secondaryLabelColor
        badge.frame = NSRect(x: 10, y: bounds.height - 42, width: 32, height: 32)
        label.preferredMaxLayoutWidth = 178
        let labelHeight = label.fittingSize.height
        label.frame = NSRect(x: 50, y: badge.frame.midY - labelHeight / 2, width: 178, height: labelHeight)
        primary.frame = NSRect(x: 122, y: 10, width: 104, height: 32)
        options.frame = NSRect(x: 10, y: 10, width: 104, height: 32)
        for button in [primary, options] {
            button.bezelStyle = .rounded; button.font = BrandTextStyle.ui.font(size: 14, weight: .semibold)
        }
        primary.isEnabled = [.available, .original, .failed, .translated].contains(state.phase)
        for view in [badge, label, options, primary] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
}

/// Dark controls paint their complete 32 pt frame with 6 pt corners.
@MainActor
private final class TranslationActionButton: NSButton {
    var onPress: (() -> Void)?
    var secondary = false
    convenience init(_ title: String, identifier: String, onPress: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.onPress = onPress
        target = self
        action = #selector(press)
        setAccessibilityIdentifier(identifier)
    }
    @objc private func press() { if isEnabled { onPress?() } }
    override func draw(_ dirtyRect: NSRect) {
        let dark = OrbitAppearance.isDark(effectiveAppearance)
        guard dark || secondary else { super.draw(dirtyRect); return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if secondary {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            path.fill()
        } else if isEnabled {
            let bottom = NSColor(srgbRed: 100/255, green: 99/255, blue: 120/255, alpha: 1)
            let top = NSColor(srgbRed: 108/255, green: 107/255, blue: 125/255, alpha: 1)
            NSGradient(starting: bottom, ending: top)?.draw(in: path, angle: 90)
            NSColor.black.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            let highlight = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5.5, yRadius: 5.5)
            NSColor.white.withAlphaComponent(0.14).setStroke()
            highlight.lineWidth = 0.5
            highlight.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            path.fill()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? BrandTextStyle.ui.font(size: 14, weight: .semibold),
            .foregroundColor: dark ? NSColor(srgbRed: 202/255, green: 201/255, blue: 224/255, alpha: 1) : NSColor.secondaryLabelColor,
            .paragraphStyle: style
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: 4, y: (bounds.height - height)/2,
                                           width: bounds.width - 8, height: height), withAttributes: attributes)
    }
}
