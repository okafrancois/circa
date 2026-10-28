import AppKit
import BrowserCore
import BrowserEngine

/// Window-local native overlay. Hover never changes the responder or creates/reparents surfaces.
@MainActor
final class FolderPreviewController<Surface: BrowserEngineSurface> {
    let intent = FolderPreviewIntent()
    let view = FolderPreviewView()
    let snapshots = BrowserSwitcherSnapshots<Surface>(attachmentPolicy: .attachedOnly)
    /// Reuse pixels captured while this window displayed the same document; never paint a detached host.
    weak var previouslyVisibleSnapshots: BrowserSwitcherSnapshots<Surface>?
    weak var anchor: SidebarListRow?
    var current: () -> BrowserOrganizationSnapshot? = { nil }
    var allowed: () -> Bool = { false }
    var surface: (TabOccurrenceID) -> Surface? = { _ in nil }
    var favicon: (BrowserOrganizationTabItem) -> NSImage? = { _ in nil }
    var activate: (TabID, UInt64, BrowserOrganizationSnapshot) -> Void = { _, _, _ in }
    private var monitor: Any?
    private var imageObservation: BrowserHookRegistration?
    private var observations: [NSObjectProtocol] = []
    private var eventEpoch: UInt64 = 0
    var isPresented: Bool { view.superview != nil }
    var onPresentationChange: (() -> Void)?
    private weak var previousResponder: NSResponder?
    private var anchorRect: NSRect = .zero

    init() {
        intent.validate = { [weak self] in self?.validate() == true }
        intent.onShow = { [weak self] in self?.show() }
        intent.onHide = { [weak self] in self?.hide() }
        intent.onResults = { [weak self] in self?.render() }
        view.onPointer = { [weak self] inside in
            guard let self else { return }
            if inside { intent.returnToPreview() }
            else if !view.ownsFocus { intent.departure() }
        }
        view.onSearch = { [weak self] query in
            self?.snapshots.shutdown()
            self?.intent.search(query)
        }
        view.onChoose = { [weak self] id in self?.choose(id) }
        view.onEscape = { [weak self] in self?.escape() }
        view.onEditingEnded = { [weak self] in
            guard let self else { return }
            let token = intent.epoch
            Task { @MainActor [weak self] in
                guard let self, self.intent.epoch == token, !self.view.ownsFocus,
                      !self.pointerInsidePreview(), self.anchor?.isHovering != true else { return }
                self.intent.departure()
            }
        }
    }

    /// The owner emits these events for autonomous navigation too, including same-URL reloads.
    func observeImages(in hooks: BrowserSurfaceEventHooks<Surface>) {
        imageObservation?.cancel()
        imageObservation = hooks.observe { [weak self] _, event in
            switch event {
            case .stateChanged, .navigationStarted, .navigationCommitted, .navigationFinished, .navigationFailed:
                guard let self, self.isPresented, self.view.isInteractive else { return }
                self.view.refreshImages()
            default: break
            }
        }
    }

    func hover(_ row: SidebarListRow, inside: Bool) {
        if !inside {
            if anchor === row, !view.ownsFocus { intent.departure() }
            return
        }
        if anchor === row, intent.phase != .idle { intent.returnToPreview(); return }
        intent.revoke()
        guard allowed(), row.commandsEnabled, !row.isRenaming, !row.isHiddenOrHasHiddenAncestor,
              let folder = row.node.folderID, let current = current(), row.window != nil else { return }
        anchor = row
        anchorRect = row.convert(row.visibleRect, to: nil)
        intent.arm(folder: folder, snapshot: current)
        installMonitor()
    }

    func invalidate(_ row: SidebarListRow) { if anchor === row { intent.revoke() } }

    func validate() -> Bool {
        guard allowed(), let row = anchor, row.window?.isKeyWindow == true,
              row.window?.attachedSheet == nil, row.commandsEnabled, !row.isRenaming,
              !row.isHiddenOrHasHiddenAncestor, row.node.folderID == intent.folder,
              !row.visibleRect.isEmpty, row.convert(row.visibleRect, to: nil) == anchorRect,
              current() == intent.snapshot else { return false }
        return true
    }

    private func show() {
        guard validate(), let row = anchor, let host = row.window?.contentView else { intent.revoke(); return }
        previousResponder = row.window?.firstResponder
        view.search.stringValue = ""
        view.title.stringValue = (row as? SidebarFolderRow)?.item.title ?? ""
        host.addSubview(view, positioned: .above, relativeTo: nil)
        onPresentationChange?()
        view.frame = FolderPreviewGeometry.frame(anchor: row.convert(row.visibleRect, to: host),
            viewport: host.bounds, flipped: host.isFlipped, count: intent.results.count)
        render()
        view.animateAppearance()
    }

    private func render() {
        guard view.superview != nil else { return }
        guard validate() else { intent.revoke(); return }
        if let host = view.superview, let row = anchor {
            view.frame = FolderPreviewGeometry.frame(anchor: row.convert(row.visibleRect, to: host),
                viewport: host.bounds, flipped: host.isFlipped, count: intent.results.count)
        }
        let token = intent.epoch
        view.render(intent.results, image: { [weak self] result in
            guard let self, token == intent.epoch, validate() else { return nil }
            return favicon(result.tab)
        })
    }

    func previewImage(for surface: Surface) -> NSImage? {
        let image = snapshots.image(for: surface) ?? previouslyVisibleSnapshots?.image(for: surface)
        snapshots.request(surface)
        return image
    }

    private func choose(_ id: TabID) {
        let token = intent.epoch
        guard let snapshot = intent.snapshot, intent.permits(id, epoch: token, current: current()) else { return }
        activate(id, token, snapshot)
    }

    func escape() {
        let restore = view.ownsFocus
        let window = view.window
        intent.revoke()
        if restore, let previous = previousResponder as? NSView, previous.window === window {
            window?.makeFirstResponder(previous)
        }
    }

    private func hide() {
        eventEpoch &+= 1
        let wasPresented = isPresented
        // Remove the field editor only when it belongs to this overlay; never steal page focus.
        if view.ownsFocus { view.window?.makeFirstResponder(nil) }
        let animate = wasPresented && intent.isDismissingAfterDeparture && !OrbitMotionPreferences.prefersReducedMotion
        if animate {
            view.isInteractive = false
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = view.layer?.presentation()?.opacity ?? 1
            animation.toValue = 0
            animation.duration = FolderPreviewMetrics.fadeDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animation.isRemovedOnCompletion = false; animation.fillMode = .forwards
            view.layer?.add(animation, forKey: "folderPreview.opacity")
            let token = eventEpoch
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(FolderPreviewMetrics.fadeDuration))
                guard let self, self.eventEpoch == token else { return }
                self.removeView()
            }
        } else { removeView() }
        snapshots.shutdown()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
        observations = []
    }

    private func removeView() {
        let wasPresented = isPresented
        view.removeFromSuperview()
        if wasPresented { onPresentationChange?() }
        view.clear()
    }

    private func pointerInsidePreview() -> Bool {
        guard let window = view.window else { return false }
        return view.bounds.contains(view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        let eventToken = eventEpoch
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.willBeginSheetNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: anchor?.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.eventEpoch == eventToken else { return }
                    self.intent.revoke()
                }
            })
        }
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: anchor?.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.eventEpoch == eventToken, self.intent.phase != .idle else { return }
                if !self.validate() { self.intent.revoke() }
            }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
            .leftMouseDragged, .keyDown, .scrollWheel, .appKitDefined]) { [weak self] event in
            guard let self, self.eventEpoch == eventToken else { return event }
            guard validate(), event.window === anchor?.window || event.type == .appKitDefined else {
                intent.revoke(); return event
            }
            if event.type == .leftMouseDragged || event.type == .rightMouseDown || event.type == .scrollWheel {
                // Native search selection, contextual editing and result scrolling belong to the overlay.
                let point = view.convert(event.locationInWindow, from: nil)
                if view.superview == nil || !view.bounds.contains(point) { intent.revoke() }
                return event
            }
            if event.type == .mouseMoved, view.superview != nil, !view.ownsFocus,
               !pointerInsidePreview(), anchor?.isHovering != true { intent.departure() }
            if event.type == .leftMouseDown {
                let point = view.convert(event.locationInWindow, from: nil)
                if view.superview == nil || !view.bounds.contains(point) { intent.revoke() }
            }
            if event.type == .keyDown {
                let editor = view.window?.firstResponder as? NSTextView
                if editor?.hasMarkedText() == true { return event }
                if event.keyCode == 53 { escape(); return nil }
                // Explicit keyboard transfer only; ordinary hover preserves the page's responder.
                if event.keyCode == 124, anchor?.isHovering == true, view.superview != nil,
                   !view.ownsFocus, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    view.window?.makeFirstResponder(view.search)
                    intent.returnToPreview()
                    return nil
                }
                if !view.ownsFocus { intent.revoke() }
            }
            return event
        }
    }

    func shutdown() {
        imageObservation?.cancel(); imageObservation = nil
        intent.revoke(); anchor = nil
    }
}

extension BrowserWindowController {
    func installFolderPreview() {
        folderPreview.observeImages(in: engineEventHooks)
        folderPreview.onPresentationChange = { [weak self] in self?.windowShell.hoverHoldDidChange() }
        folderPreview.current = { [weak self] in self?.session.organization }
        folderPreview.allowed = { [weak self] in
            guard let self else { return false }
            return acceptsCommands && !session.isClosed && !palette.isPresented && !library.isPresented
                && !peek.isPresented && themeEditor == nil && tabSwitcher.view.superview == nil
                && sidebar.contextMenuNodes.isEmpty && sidebar.page.list.renamingNode == nil
                && !sidebar.isPresentationHidden && !sidebar.isSwitchingSpace
        }
        folderPreview.surface = { [weak self] in self?.session.surface(for: $0) }
        // The sidebar's resolver reads decoded, profile-local pixels synchronously, including
        // dormant tabs. A known icon is installed before the first preview frame is exposed.
        folderPreview.favicon = { [weak self] in self?.sidebar.liveActivity($0).favicon }
        sidebar.onFolderHover = { [weak self] in self?.folderPreview.hover($0, inside: $1) }
        sidebar.onPreviewInvalidated = { [weak self] in self?.folderPreview.invalidate($0) }
        folderPreview.activate = { [weak self] id, token, snapshot in
            guard let self else { return }
            let admission = folderPreview.intent.admission
            submitInput { owner in
                owner.activateSidebarTab(id, expecting: snapshot, admission: admission, isCurrent: { [weak owner] in
                    guard let owner else { return false }
                    return owner.folderPreview.intent.permits(id, epoch: token, current: owner.session.organization)
                })
            }
        }
    }
}
