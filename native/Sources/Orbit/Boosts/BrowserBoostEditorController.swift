import AppKit
import BrowserCore
import BrowserEngine

@MainActor
final class BrowserBoostEditorController: NSWindowController {
    let session: BrowserBoostEditorSession
    let editor: BrowserBoostEditorView
    var zapView: BrowserBoostZapView?
    weak var pageHost: NSView?
    private weak var presentingWindow: NSWindow?
    private(set) var deleteConfirmation: BrowserBoostDeleteView?
    private var resizeTimer: Timer?
    private var resizeBegan: TimeInterval?
    init(session: BrowserBoostEditorSession, parent: NSWindow, firstRun: Bool) {
        self.session = session
        editor = BrowserBoostEditorView(session: session, firstRun: firstRun)
        let panel = BrowserBoostPanel(contentRect: NSRect(x: 0, y: 0, width: 183, height: 588),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = editor
        super.init(window: panel)
        presentingWindow = parent
        editor.onClose = { [weak self] in self?.close() }
        editor.onDelete = { [weak self] in self?.confirmDelete() }
        editor.onCode = { [weak self] in self?.showCode() }
        panel.title = uiText("Boost")
        panel.setAccessibilityLabel(uiText("Boost"))
        // Settled geometry; presentation has no custom transition.
        let available = parent.screen?.visibleFrame ?? parent.frame
        let x = min(available.maxX - 193, max(available.minX + 10, parent.frame.maxX - 406))
        let y = min(available.maxY - 598, max(available.minY + 10, parent.frame.maxY - 735))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        parent.addChildWindow(panel, ordered: .above)
    }
    required init?(coder: NSCoder) { nil }
    func showCode() {
        guard let window else { return }
        let code = BrowserBoostCodeView(session: session)
        code.requestJavaScriptConsent = { [weak self] completion in
            guard let self, let window = self.window, !session.isClosed else { completion(false); return }
            let alert = NSAlert()
            alert.messageText = uiText("Enable JavaScript for this Boost?")
            alert.informativeText = uiText("Only enable code you trust. JavaScript can read and change this site's pages. Changes run after reloading the page; disabling or deleting a Boost cannot undo code that already ran.")
            alert.addButton(withTitle: uiText("Enable JavaScript"))
            alert.addButton(withTitle: uiText("Cancel"))
            alert.beginSheetModal(for: window) { response in completion(response == .alertFirstButtonReturn) }
        }
        code.onBack = { [weak self] in self?.showControls() }
        var frame = window.frame
        frame.origin.x -= 480 - frame.width; frame.size.width = 480
        window.contentView = code
        resize(to: frame)
    }
    func showControls() {
        guard let window else { return }
        var frame = window.frame
        frame.origin.x += frame.width - 183; frame.size.width = 183
        resize(to: frame) { [weak self] in guard let self else { return }; window.contentView = editor }
    }
    func confirmDelete() {
        guard deleteConfirmation == nil, !session.isClosed,
              let parent = presentingWindow, let host = parent.contentView else { return }
        zapView?.stop(); zapView = nil; editor.isZapping = false
        let view = BrowserBoostDeleteView { [weak self] accepted in
            guard let self else { return }
            deleteConfirmation = nil
            if accepted { session.delete() }
            Task { [weak self] in
                guard let self else { return }
                await session.pending?.value
                if session.isDeleted { close() }
                else if !session.isClosed, let panel = window, let parent = presentingWindow {
                    if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
                    panel.makeKeyAndOrderFront(nil)
                }
            }
        }
        view.frame = host.bounds; view.autoresizingMask = [.width, .height]
        host.addSubview(view, positioned: .above, relativeTo: nil)
        deleteConfirmation = view
        if let window { parent.removeChildWindow(window); window.orderOut(nil) }
        parent.makeKeyAndOrderFront(nil)
    }

    private func resize(to target: NSRect, completion: (@MainActor @Sendable () -> Void)? = nil) {
        resizeTimer?.invalidate()
        guard let window else { return }
        guard !OrbitMotionPreferences.prefersReducedMotion else {
            window.setFrame(target, display: true); completion?(); return
        }
        let start = window.frame
        resizeBegan = nil
        // Sampled 60 Hz progression for a 0.45-second, right-anchored expansion.
        let progress: [Double] = [0, 0.045, 0.123, 0.123, 0.323, 0.323, 0.471, 0.562,
            0.643, 0.710, 0.744, 0.744, 0.821, 0.869, 0.902, 0.933, 0.946, 0.963,
            0.963, 0.973, 0.985, 0.992, 0.997, 0.997, 1, 1.002, 1.002, 1]
        resizeTimer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let began = self.resizeBegan ?? now
                self.resizeBegan = began
                let sample = (now - began) * 60
                let index = min(progress.count - 1, Int(sample))
                let next = min(index + 1, progress.count - 1)
                let amount = progress[index] + (progress[next] - progress[index]) * (sample - floor(sample))
                var frame = start
                frame.size.width = start.width + (target.width - start.width) * amount
                frame.origin.x = target.maxX - frame.width
                window.setFrame(frame, display: true)
                if sample >= Double(progress.count - 1) { self.resizeTimer?.invalidate(); self.resizeTimer = nil; window.setFrame(target, display: true); completion?() }
            }
        }
        if let resizeTimer { RunLoop.main.add(resizeTimer, forMode: .common) }
    }
    override func close() {
        resizeTimer?.invalidate(); resizeTimer = nil
        deleteConfirmation?.removeFromSuperview(); deleteConfirmation = nil
        zapView?.stop(); zapView = nil
        session.close()
        if let window { window.parent?.removeChildWindow(window) }
        super.close()
    }
}

@MainActor
private final class BrowserBoostPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
enum BrowserBoostCommands {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        try! registry.register(.newBoost, validate: { $0.canCreateBoost }) { owner, _ in owner.createBoost() }
        try! registry.register(.viewBoosts) { owner, _ in owner.showLibrary(.boosts) }
    }
}

extension BrowserWindowController {
    var canCreateBoost: Bool {
        guard !isPrivateWindow, boostsRuntime != nil, let url = pageCommandSurface()?.navigationState.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil,
              let scheme = parts.scheme, ["http", "https"].contains(scheme),
              let host = parts.encodedHost else { return false }
        return (try? BrowserBoostHostPattern(host: host, schemes: [scheme == "https" ? .https : .http], port: parts.port)) != nil
    }

    func createBoost() {
        guard canCreateBoost, let runtime = boostsRuntime, let surface = pageCommandSurface(),
              let url = surface.navigationState.url, let parent = window else { return }
        let generation = surface.documentGeneration, profile = surface.profileID
        boostTask = Task { [weak self, weak surface] in
            guard let self, let surface else { return }
            do {
                let store = try runtime.store(for: profile)
                guard isBoostPageTarget(surface), surface.documentGeneration == generation else { return }
                let draft = try await BrowserBoostEditorSession.create(in: store, url: url, title: uiText("My Boost"))
                guard !Task.isCancelled, isBoostPageTarget(surface), surface.documentGeneration == generation,
                      session.activeProfileID == profile, acceptsCommands else { return }
                presentBoost(draft, parent: parent)
                try await synchronizeBoosts(profile)
            } catch { session.onError?(error) }
        }
    }

    func presentBoost(_ draft: BrowserBoostEditorSession, parent: NSWindow) {
        boostEditor?.close()
        let firstRun = !(settingsPreferences?.runtime.document.hasSeenBoostsIntroduction ?? boostsIntroduced)
        boostsIntroduced = true
        if firstRun, let preferences = settingsPreferences?.runtime {
            Task { [weak self] in
                do { try await preferences.markBoostsIntroductionSeen() }
                catch { self?.session.onError?(error) }
            }
        }
        let controller = BrowserBoostEditorController(session: draft, parent: parent, firstRun: firstRun)
        controller.editor.onAllBoosts = { [weak self, weak controller] in
            controller?.close()
            self?.showLibrary(.boosts)
        }
        controller.pageHost = pageCommandSurface()?.hostView
        let profile = draft.store.profileID
        draft.onCommit = { [weak self] in
            guard let self else { return }
            defer { renderLibraryBoosts() }
            try await synchronizeBoosts(profile)
        }
        controller.editor.onZap = { [weak self, weak controller] in
            guard let self, let controller else { return }
            beginBoostZap(controller)
        }
        controller.editor.onRender = { [weak controller] in
            guard let controller else { return }
            controller.zapView?.renderZaps(controller.session.boost.content.zapSelectors)
        }
        boostEditor = controller
        if parent.isVisible { controller.showWindow(nil) }
    }

    func isBoostPageTarget(_ surface: Surface) -> Bool {
        (owns(surface) || peek.owns(surface)) && pageCommandSurface() === surface
    }

    func closeBoostEditor(on surface: Surface) {
        guard let editor = boostEditor, editor.pageHost === surface.hostView else { return }
        editor.close()
        boostEditor = nil
    }

    func beginBoostZap(_ controller: BrowserBoostEditorController) {
        if let picker = controller.zapView { picker.stop(); controller.zapView = nil; controller.editor.isZapping = false; return }
        guard let surface = pageCommandSurface(), isBoostPageTarget(surface),
              controller.pageHost === surface.hostView, surface.profileID == controller.session.store.profileID,
              let probe = engine.conformanceProbe else { return }
        let generation = surface.documentGeneration
        let picker = BrowserBoostZapView(frame: surface.hostView.bounds)
        picker.autoresizingMask = [.width, .height]
        picker.inspect = { [weak self, weak surface] point in
            guard let self, let surface, isBoostPageTarget(surface),
                  surface.documentGeneration == generation else { throw BrowserEngineError.documentChanged }
            let raw = try await probe.evaluateScript(BrowserBoostZapView.script(at: point, zoom: surface.pageZoom), in: surface)
            guard isBoostPageTarget(surface), surface.documentGeneration == generation,
                  let raw, raw != "null", let data = raw.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(BrowserBoostPickedElement.self, from: data)
        }
        picker.onStop = { [weak self, weak surface] in
            guard let self, let surface, isBoostPageTarget(surface) else { return }
            surface.focusDocument()
        }
        picker.onZap = { [weak controller] in controller?.session.zap($0) }
        picker.onUnzap = { [weak controller] in controller?.session.unzap($0) }
        picker.onError = { [weak picker] _ in picker?.onDone?() }
        picker.onDone = { [weak controller, weak picker] in picker?.stop(); controller?.zapView = nil; controller?.editor.isZapping = false }
        picker.renderZaps(controller.session.boost.content.zapSelectors)
        controller.zapView = picker
        controller.editor.isZapping = true
        surface.hostView.addSubview(picker, positioned: .above, relativeTo: nil)
        window?.makeFirstResponder(picker)
    }

    func synchronizeBoosts(_ profile: ProfileID) async throws {
        guard let runtime = boostsRuntime else { return }
        // Unsupported engines retain edits; no fallback page injection is installed.
        guard runtime.hostOverride != nil || (engine.capabilities.contains(.boosts) && engine.boosts != nil) else { return }
        try await runtime.synchronize(profileID: profile,
            enabled: settingsPreferences?.runtime.document.enablesBoostsOnWebsites ?? true, engine: engine)
    }

    func renderLibraryBoosts() {
        guard library.isPresented, library.category == .boosts, let profile = session.activeProfileID,
              let runtime = boostsRuntime else { return }
        library.boostsView.selectProfile(profile)
        let ticket = library.presentationID
        library.boostsTask?.cancel()
        library.boostsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let document = await (try runtime.store(for: profile)).snapshot()
                guard !Task.isCancelled, library.isPresented, library.category == .boosts,
                      library.presentationID == ticket, session.activeProfileID == profile else { return }
                library.boostsView.render(document.boosts, profile: profile)
            } catch { session.onError?(error) }
        }
    }

    func openLibraryBoost(_ boost: BrowserBoost, profile: ProfileID) {
        guard library.isPresented, library.category == .boosts, session.activeProfileID == profile,
              let runtime = boostsRuntime, let parent = window else { return }
        boostTask?.cancel()
        let ticket = library.presentationID
        let sourceSpace = session.snapshot?.activeSpaceID
        let sourceOccurrence = session.snapshot?.selectedOccurrenceID
        boostTask = Task { [weak self] in
            guard let self else { return }
            do {
                let store = try runtime.store(for: profile)
                guard let current = await store.snapshot().boosts.first(where: { $0.id == boost.id }),
                      !Task.isCancelled, library.isPresented, library.category == .boosts,
                      library.presentationID == ticket,
                      session.snapshot?.activeSpaceID == sourceSpace,
                      session.snapshot?.selectedOccurrenceID == sourceOccurrence,
                      session.activeProfileID == profile, acceptsCommands else { return }
                var parts = URLComponents()
                parts.scheme = current.hostPattern.schemes.contains(.https) ? "https" : "http"
                parts.host = current.hostPattern.host; parts.port = current.hostPattern.port
                guard let url = parts.url else { return }
                guard openLibraryBoostPage(url, profile: profile) != nil else { return }
                presentBoost(.init(store: store, boost: current), parent: parent)
                try await synchronizeBoosts(profile)
            } catch { session.onError?(error) }
        }
    }
}
