import AppKit
import BrowserCore
import BrowserEngine

/// Window-owned input mode: no application-global history, no engine surface reparenting.
@MainActor
final class BrowserTabSwitcher<Engine: BrowserEngine> {
    private weak var owner: BrowserWindowController<Engine>?
    let model = BrowserTabSwitcherModel()
    let snapshots: BrowserSwitcherSnapshots<Engine.Surface>
    let view = BrowserSwitcherView()
    let icons: FavoriteIconPipeline<Engine.Surface>
    private var resignObserver: NSObjectProtocol?
    private var hook: BrowserHookRegistration?
    private var reveal: Task<Void, Never>?
    private var isVisible = false
    private weak var presentedSurface: Engine.Surface?
    private var tabs: [TabOccurrenceID: BrowserOrganizationTabItem] = [:]
    /// Injectable for deterministic hidden tests; production checks the physical modifier state
    /// at delivery time, rather than trusting a possibly queued keyDown.
    var controlIsHeld: () -> Bool = { NSEvent.modifierFlags.contains(.control) }
    private var gestureModifiers: NSEvent.ModifierFlags = .control
    private var closeBoundary: Task<BrowserContext?, Never>?

    init(owner: BrowserWindowController<Engine>) {
        self.owner = owner
        snapshots = BrowserSwitcherSnapshots()
        icons = FavoriteIconPipeline()
        owner.folderPreview.previouslyVisibleSnapshots = snapshots
        snapshots.onChange = { [weak self] in
            self?.renderOverlay()
            self?.owner?.folderPreview.view.refreshImages()
        }
        icons.onChange = { [weak self] in self?.renderOverlay() }
        view.onHover = { [weak self] id in self?.model.highlight(id); self?.renderOverlay() }
        view.onChoose = { [weak self] id in self?.model.highlight(id); self?.commit() }
        hook = owner.engineEventHooks.observe { [weak self] surface, event in
            guard let self else { return }
            if event == .navigationStarted || event == .navigationCommitted {
                self.snapshots.invalidate(surface)
                self.renderOverlay()
            }
            if event == .navigationFinished {
                self.snapshots.invalidate(surface)
                if self.isVisible { self.snapshots.request(surface) }
            }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: owner.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
    }

    /// Called before the content card replaces its engine view, once per actual selection change.
    func prepareForPresentation(_ surface: Engine.Surface?) -> Task<Void, Never>? {
        guard presentedSurface !== surface else { return nil }
        let outgoing = presentedSurface
        presentedSurface = surface
        if let surface { snapshots.cancelPendingCapture(for: surface) }
        guard let outgoing else { return nil }
        return snapshots.request(outgoing, freshness: 0.3)
    }

    func renderSession() {
        guard let owner, !owner.session.isClosed, let snapshot = owner.session.snapshot else { cancel(); return }
        tabs = Dictionary((owner.session.organization?.allTabs ?? []).compactMap { tab in
            tab.occurrenceID.map { ($0, tab) }
        }, uniquingKeysWith: { _, latest in latest })
        let ids = snapshot.tabs.map(\.occurrenceID)
        model.reconcile(space: snapshot.activeSpaceID, available: ids, selected: snapshot.selectedOccurrenceID)
        snapshots.retain(owner.session.ownedSurfaces)
        icons.retain(Set(owner.session.organization?.allTabs.map(\.id) ?? []))
        if !model.isActive { closeBoundary = nil; hide() }
        if isVisible { renderOverlay() }
    }

    func cycle(backward: Bool = false, holding modifiers: NSEvent.ModifierFlags? = nil) {
        if !model.isActive { gestureModifiers = modifiers?.intersection([.command, .control, .option]) ?? .control }
        if model.spaceID == nil { renderSession() }
        let wasActive = model.isActive
        model.cycle(backward: backward)
        guard model.isActive else { return }
        let held = gestureModifiers == .control ? controlIsHeld() : NSEvent.modifierFlags.isSuperset(of: gestureModifiers)
        guard !gestureModifiers.isEmpty, held else { commit(); return }
        if !wasActive {
            reveal = Task { [weak self] in
                try? await Task.sleep(nanoseconds: OrbitTokens.Switcher.revealDelay)
                guard !Task.isCancelled, let self, self.model.isActive else { return }
                self.show()
            }
        }
        if isVisible { renderOverlay() }
    }

    /// flagsChanged carries the remaining modifiers, not the modifier that changed.
    func modifiersChanged(controlHeld: Bool) { if !controlHeld { commit() } }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        if !flags.isSuperset(of: gestureModifiers) { commit() }
    }

    func commit() {
        guard let owner, let original = owner.session.snapshot else { cancel(); return }
        let id = model.releaseControl()
        hide()
        guard let id else { return }
        owner.recordExplicitInput()
        let closing = closeBoundary
        closeBoundary = nil
        let capture = owner.session.captureContextInCommandOrder()
        Task { [weak owner] in
            guard let context = await capture.value, let owner,
                  context.windowID == original.id, context.spaceID == original.activeSpaceID else { return }
            if let closing {
                guard await closing.value == context else { return }
            } else {
                guard context.revision == original.revision else { return }
            }
            owner.hideLibrary()
            _ = owner.session.selectSidebarOccurrence(id, ifContextMatches: context)
        }
    }

    func closeHighlighted() {
        guard let owner, let id = model.removeHighlighted() else { return }
        if let surface = owner.session.surface(for: id) { snapshots.invalidate(surface) }
        owner.session.closeOccurrence(id)
        closeBoundary = owner.session.captureContextInCommandOrder()
        if model.isActive { renderOverlay() } else { hide() }
    }

    func cancel() { model.cancel(); closeBoundary = nil; hide() }

    func show() {
        guard let root = owner?.window?.contentView else { return }
        isVisible = true
        root.addSubview(view, positioned: .above, relativeTo: nil)
        renderOverlay()
    }

    private func hide() {
        reveal?.cancel()
        reveal = nil
        isVisible = false
        snapshots.protect([])
        view.removeFromSuperview()
    }

    private func renderOverlay() {
        guard isVisible, model.isActive, let owner, let root = owner.window?.contentView else { return }
        let highlightIndex = model.candidates.firstIndex(of: model.highlightedID ?? model.candidates[0]) ?? 0
        let fit = BrowserSwitcherView.cardsThatFit(width: root.bounds.width)
        let start = max(0, min(highlightIndex - fit / 2, model.candidates.count - fit))
        let visible = model.candidates.dropFirst(start).prefix(fit)
        snapshots.protect(visible.compactMap { owner.session.surface(for: $0) })
        let items = visible.compactMap { id -> BrowserSwitcherView.Item? in
            guard let surface = owner.session.surface(for: id) else { return nil }
            let title = tabs[id]?.title
                ?? surface.navigationState.title ?? surface.currentURL?.host ?? uiText("New Tab")
            let tab = tabs[id]
            let icon = tab.flatMap { icons.image(for: $0, surface: surface, isOwned: { [weak owner] in owner?.owns($0) == true }) }
            return .init(id: id, title: title, image: snapshots.image(for: surface), icon: icon)
        }
        let width = min(root.bounds.width - OrbitTokens.Switcher.padding * 2, OrbitTokens.Switcher.maximumWidth,
            CGFloat(items.count) * OrbitTokens.Switcher.cardWidth + CGFloat(max(0, items.count - 1)) * OrbitTokens.Switcher.gap + OrbitTokens.Switcher.padding * 2)
        let height = OrbitTokens.Switcher.cardHeight + OrbitTokens.Switcher.padding * 2
        view.frame = NSRect(x: (root.bounds.width - width) / 2, y: (root.bounds.height - height) / 2,
            width: width, height: height)
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        view.setAccessibilityLabel(uiFormat("Tab Switcher, %ld of %ld", highlightIndex + 1, model.candidates.count))
        view.render(items, selected: model.highlightedID)
        // Begin work only after the overlay is built. Limit captures even with thousands of tabs.
        let targets = ([model.highlightedID].compactMap { $0 } + Array(visible)).prefix(snapshots.capacity)
        for id in targets {
            if let surface = owner.session.surface(for: id) { snapshots.request(surface) }
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            modifiersChanged(event.modifierFlags)
            return true
        }
        if event.type == .leftMouseDown {
            if !isVisible || !view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { cancel(); return true }
            return false
        }
        guard event.type == .keyDown else { return false }
        if let text = owner?.window?.firstResponder as? NSTextView, text.hasMarkedText() { return false }
        switch event.keyCode {
        case 53: cancel(); return true
        case 36, 76: commit(); return true
        default:
            // Control-arrow combinations may be intercepted by macOS Spaces/Mission Control.
            // Only Tab and Control-W are delegated to the command registry while this mode owns input.
            if event.keyCode == 48 || !event.modifierFlags.intersection([.control, .command, .option]).isEmpty { return false }
            if event.modifierFlags.intersection([.control, .command, .option, .shift]) == .control,
               event.charactersIgnoringModifiers?.lowercased() == "w" { return false }
            return true
        }
    }

    func shutdown() {
        cancel()
        snapshots.shutdown()
        icons.clear()
        hook?.cancel()
        hook = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
