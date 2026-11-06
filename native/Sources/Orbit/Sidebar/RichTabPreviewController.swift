import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Window-local hover intent. Rendering reads bounded memory caches; it never activates a tab.
@MainActor
final class RichTabPreviewController {
    static let dwell: TimeInterval = 0.12
    static let entryDuration: TimeInterval = 0.09
    static let exitDuration: TimeInterval = 0.08
    static let crossingGrace: TimeInterval = 0.10
    let view = RichTabPreviewView()
    private(set) weak var row: SidebarTabRow?
    private var identity: RichTabPreviewIdentity?
    private var anchor = NSRect.zero
    private var epoch: UInt64 = 0
    private var pending: (any OrbitCancellable)?
    private var monitor: Any?
    private var observations: [NSObjectProtocol] = []
    var imageObservation: BrowserHookRegistration?
    var allowed: () -> Bool = { false }
    var content: (TabID) -> RichTabPreviewContent? = { _ in nil }
    var action: (RichTabPreviewAction, RichTabPreviewIdentity) -> Void = { _, _ in }
    var onPresentationChange: (() -> Void)?
    var reducedMotion: () -> Bool = { OrbitMotionPreferences.prefersReducedMotion }
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> any OrbitCancellable = {
        OrbitRunLoopTimer(after: $0, $1)
    }
    var isPresented: Bool { view.superview != nil && view.isInteractive }

    init() {
        view.onPointer = { [weak self] inside in
            guard let self, isPresented else { return }
            if inside { cancelPending() } else { depart() }
        }
        view.onAction = { [weak self] in self?.invoke($0) }
    }

    @discardableResult
    func hover(_ candidate: SidebarTabRow, inside: Bool) -> Bool {
        guard inside else {
            if row === candidate { depart() }
            return row === candidate
        }
        guard allowed(), candidate.commandsEnabled, !candidate.isRenaming,
              candidate.window?.isKeyWindow == true, let current = content(candidate.item.id) else { dismiss(); return false }
        if row === candidate, identity == current.identity {
            if isPresented { cancelPending() }
            return true
        }
        let handoff = view.superview != nil && view.window === candidate.window
        dismiss(keepingView: handoff)
        row = candidate
        identity = current.identity
        anchor = candidate.convert(candidate.bounds, to: nil)
        installMonitor(in: candidate.window!)
        if handoff || reducedMotion() { present(animated: false) }
        else {
            let token = epoch
            pending = schedule(Self.dwell) { [weak self] in
                guard let self, epoch == token else { return }
                present(animated: true)
            }
        }
        return true
    }

    private func current() -> RichTabPreviewContent? {
        guard allowed(), let row, row.commandsEnabled, !row.isRenaming,
              !row.isHiddenOrHasHiddenAncestor, !row.visibleRect.isEmpty,
              row.window?.isKeyWindow == true, row.window?.attachedSheet == nil,
              row.convert(row.bounds, to: nil) == anchor,
              let current = content(row.item.id), current.identity == identity else { return nil }
        return current
    }

    func reconcile() {
        guard row != nil else { return }
        guard let current = current() else { dismiss(); return }
        if isPresented { view.configure(current) }
    }

    func invalidate(_ candidate: SidebarListRow) { if row === candidate { dismiss() } }
    func shutdown() { dismiss(); imageObservation?.cancel(); imageObservation = nil }

    private func present(animated: Bool) {
        guard let current = current(), let row, let host = row.window?.contentView else { dismiss(); return }
        cancelPending()
        view.layer?.removeAnimation(forKey: "rich-entry")
        view.layer?.removeAnimation(forKey: "rich-exit")
        view.alphaValue = 1
        view.isInteractive = true
        view.configure(current)
        // Rows permit drawing outside their bounds; visibleRect can cover the whole viewport.
        let frame = row.convert(row.bounds.intersection(row.visibleRect), to: host)
        view.frame = Self.frame(anchor: frame, bounds: host.bounds, flipped: host.isFlipped)
        if view.superview !== host { host.addSubview(view, positioned: .above, relativeTo: nil) }
        if animated, !reducedMotion() {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = Self.entryDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer?.add(fade, forKey: "rich-entry")
        }
        onPresentationChange?()
    }

    static func frame(anchor: NSRect, bounds: NSRect, flipped: Bool) -> NSRect {
        let size = NSSize(width: min(RichTabPreviewView.size.width, max(0, bounds.width - 16)),
                          height: min(RichTabPreviewView.size.height, max(0, bounds.height - 16)))
        let x = min(max(bounds.minX + 8, anchor.maxX + 8), bounds.maxX - size.width - 8)
        // Keep the action row beside the hovered tab so reaching it does not cross other tabs.
        let y = flipped ? anchor.maxY - size.height : anchor.minY
        return NSRect(x: x, y: max(bounds.minY + 8, min(y, bounds.maxY - size.height - 8)), width: size.width, height: size.height)
    }

    private func pointerInside() -> Bool {
        guard let window = view.window, isPresented else { return false }
        return view.bounds.contains(view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    private func depart() {
        guard !pointerInside() else { cancelPending(); return }
        cancelPending()
        guard view.superview != nil else { dismiss(); return }
        let token = epoch
        pending = schedule(Self.crossingGrace) { [weak self] in
            guard let self, epoch == token, !pointerInside() else { return }
            dismiss(animated: true)
        }
    }

    func invoke(_ selected: RichTabPreviewAction) {
        guard isPresented, let current = current(),
              selected != .ask || current.canAsk,
              selected != .pin || !current.isFavorite else { dismiss(); return }
        let captured = current.identity
        dismiss()
        action(selected, captured)
    }

    /// A new composer targets the requested tab, rather than its automatic active-page chip.
    /// An existing draft keeps the sources the user already chose.
    static func selectSource(_ source: BrowserAIContextSource, in conversation: BrowserAIConversation,
                             replacingAutomaticContext: Bool) {
        if replacingAutomaticContext {
            for selected in conversation.selectedSources { conversation.removeSource(selected.id) }
        }
        conversation.select(source)
    }

    private func cancelPending() { epoch &+= 1; pending?.cancel(); pending = nil }

    func dismiss(animated: Bool = false, keepingView: Bool = false) {
        epoch &+= 1
        cancelPending()
        row = nil; identity = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        for observer in observations { NotificationCenter.default.removeObserver(observer) }; observations = []
        guard !keepingView else { return }
        let wasPresented = view.superview != nil
        view.isInteractive = false
        guard animated, wasPresented, !reducedMotion() else {
            view.removeFromSuperview()
            view.clear()
            if wasPresented { onPresentationChange?() }
            return
        }
        let token = epoch
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = view.layer?.presentation()?.opacity ?? 1
        fade.toValue = 0; fade.duration = Self.exitDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        view.layer?.add(fade, forKey: "rich-exit")
        pending = schedule(Self.exitDuration) { [weak self] in
            guard let self, epoch == token else { return }
            view.removeFromSuperview(); pending = nil
            view.clear()
            onPresentationChange?()
        }
    }

    private func installMonitor(in window: NSWindow) {
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.willBeginSheetNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            let inCard = event.window === self.view.window && self.isPresented && self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil))
            if event.type == .keyDown {
                let consumed = event.keyCode == 53 && self.isPresented
                self.dismiss()
                return consumed ? nil : event
            }
            if !inCard || event.type == .leftMouseDragged || event.type == .rightMouseDown { self.dismiss() }
            return event
        }
    }
}

extension BrowserWindowController {
    func installRichTabPreview() {
        richTabPreview.imageObservation = engineEventHooks.observe { [weak self] _, event in
            switch event {
            case .stateChanged, .navigationStarted, .navigationCommitted, .navigationFinished, .navigationFailed:
                self?.richTabPreview.reconcile()
            default: break
            }
        }
        folderPreview.snapshots.onChange = { [weak self] in
            self?.folderPreview.view.refreshImages()
            self?.richTabPreview.reconcile()
        }
        richTabPreview.allowed = { [weak self] in
            guard let self else { return false }
            return acceptsCommands && !session.isClosed && !palette.isPresented && !library.isPresented
                && !peek.isPresented && themeEditor == nil && tabSwitcher.view.superview == nil
                && sidebar.contextMenuNodes.isEmpty && sidebar.page.list.renamingNode == nil
                && !sidebar.isPresentationHidden && !sidebar.isSwitchingSpace && !folderPreview.isPresented
                && favorites?.gmailPreview.isPresented != true
        }
        richTabPreview.content = { [weak self] id in self?.richTabContent(id) }
        richTabPreview.onPresentationChange = { [weak self] in self?.windowShell.hoverHoldDidChange() }
        richTabPreview.action = { [weak self] action, captured in
            self?.submitInput { owner in
                guard owner.richTabContent(captured.tab)?.identity == captured else { return }
                switch action {
                case .pin:
                    if case .pinned = captured.section { owner.session.unpinTabs([captured.tab]) }
                    else { owner.session.pinTabs([captured.tab]) }
                case .favorite:
                    if case .favorites = captured.section { owner.session.removeFromFavorites([captured.tab]) }
                    else { owner.session.addToFavorites([captured.tab]) }
                case .split: owner.session.openTabInSplit(captured.tab)
                case .ask:
                    guard owner.assistantEnabled, let source = owner.assistantSources.first(where: { $0.id == captured.tab.rawValue }) else { return }
                    let previous = owner.aiConversation
                    guard let conversation = owner.ensureAssistant() else { return }
                    RichTabPreviewController.selectSource(source, in: conversation, replacingAutomaticContext: previous !== conversation)
                    if owner.assistantHost == nil { owner.toggleAssistant() }
                    owner.reconcileAssistant()
                }
            }
        }
    }

    func richTabContent(_ id: TabID) -> RichTabPreviewContent? {
        guard let current = session.organization, let tab = current.tab(id) else { return nil }
        let surface = tab.occurrenceID.flatMap { session.surface(for: $0) }
        guard surface.map({ owns($0) && !$0.isDisposed }) != false else { return nil }
        let identity = RichTabPreviewIdentity(profile: current.profileID, space: current.spaceID,
            tab: id, occurrence: tab.occurrenceID, generation: surface?.documentGeneration,
            url: tab.url, section: tab.section)
        return RichTabPreviewContent(identity: identity, title: tab.title ?? tab.url.host ?? tab.url.absoluteString,
            icon: sidebar.liveActivity(tab).favicon,
            snapshot: surface.flatMap { folderPreview.previewImage(for: $0) },
            canAsk: assistantEnabled && assistantSources.contains { $0.id == id.rawValue })
    }
}
