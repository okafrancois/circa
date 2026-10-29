import AppKit
import BrowserEngine
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
            } catch { /* A navigation or unsupported document has no offer. */ }
        }
    }

    func begin(in root: NSView) {
        guard isCurrent, state.begin() else { return }
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

    func restore() async {
        guard let surface, isCurrent else { return }
        revision += 1
        configuration = nil
        do {
            try await surface.restoreTranslation()
            guard isCurrent else { return }
            state.restore()
        } catch { if isCurrent { state.fail() } }
        onChange?()
    }

    func retire() {
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
    let popover = NSPopover()
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
        update()
    }
    private func update() {
        owner?.addressField.setStatus(status)
        owner?.addressField.setAccessibilityHelp(status)
        owner?.addressField.setAccessibilityCustomActions(status == nil ? [] : [
            NSAccessibilityCustomAction(name: uiText("Translate")) { [weak self] in self?.show(); return true }
        ])
        if popover.isShown, presentedPage !== page { popover.close() }
    }
    func show() {
        guard let owner, let page, page.state.phase != .unavailable else { return }
        if popover.isShown { popover.close(); return }
        presentedPage = page
        let view = BrowserTranslationPopover(state: page.state) { [weak self, weak page, weak owner] in
            guard let self, let page, let owner, self.page === page else { return }
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
    func close() {
        popover.close()
        // A released surface belongs to its receiver or the rescue holder, even if this
        // window closes while adoption is pending. Only retire documents still owned here.
        for surface in owner?.session.ownedSurfaces ?? [] {
            pages.removeValue(forKey: ObjectIdentifier(surface))?.retire()
        }
    }
}

/// 236 × 100 pt content, 32 pt language badge, 104 × 32 pt actions and 10 pt insets.
@MainActor
final class BrowserTranslationPopover: NSView {
    let primary: NSButton
    init(state: BrowserTranslationState, action: @escaping () -> Void) {
        let translated = state.phase == .translated
        primary = TranslationActionButton(translated ? uiText("Use Original") : uiText("Translate"), identifier: "translation-primary", onPress: action)
        super.init(frame: NSRect(x: 0, y: 0, width: 236, height: translated ? 96 : 100))
        let badge = NSView()
        let badgeLabel = NSTextField(labelWithString: uiText("Aa"))
        badgeLabel.frame = NSRect(x: 0, y: 6, width: 32, height: 20)
        badge.addSubview(badgeLabel)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .center; badgeLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        badge.wantsLayer = true; badge.layer?.cornerRadius = 16
        badge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        let locale = Locale.current
        let language = locale.localizedString(forLanguageCode: translated ? state.source : state.target) ?? (translated ? state.source : state.target)
        let message = translated ? uiFormat("Translated from %@.", language) : uiFormat("Translate this page\nto %@?", language)
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 14); label.textColor = .secondaryLabelColor
        badge.frame = NSRect(x: 10, y: bounds.height - 42, width: 32, height: 32)
        label.preferredMaxLayoutWidth = 178
        let labelHeight = label.fittingSize.height
        label.frame = NSRect(x: 50, y: badge.frame.midY - labelHeight / 2, width: 178, height: labelHeight)
        primary.frame = NSRect(x: 122, y: 8, width: 104, height: 32)
        for button in [primary] {
            button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 14, weight: .semibold)
        }
        primary.isEnabled = [.available, .original, .failed, .translated].contains(state.phase)
        for view in [badge, label, primary] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
}

/// Dark controls paint their complete 32 pt frame with 6 pt corners.
@MainActor
private final class TranslationActionButton: NSButton {
    private var onPress: (() -> Void)?
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
        guard OrbitAppearance.isDark(effectiveAppearance) else { super.draw(dirtyRect); return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if isEnabled {
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
            .font: font ?? NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 202/255, green: 201/255, blue: 224/255, alpha: 1),
            .paragraphStyle: style
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: 4, y: (bounds.height - height)/2,
                                           width: bounds.width - 8, height: height), withAttributes: attributes)
    }
}
