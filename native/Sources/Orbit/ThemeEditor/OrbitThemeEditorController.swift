import AppKit
import BrowserCore
import QuartzCore

/// Reject native replay before UndoManager pops its history entry. A cancelled termination can
/// then thaw the same window with its complete undo/redo history intact.
@MainActor
final class OrbitThemeUndoManager: UndoManager {
    weak var registry: OrbitThemeEditorRegistry?

    var allowsReplay: Bool { registry?.isFrozen != true }

    override func undo() {
        guard allowsReplay else { return }
        super.undo()
    }

    override func redo() {
        guard allowsReplay else { return }
        super.redo()
    }
}

/// Borderless key panel hosting the editor over its parent window (Orbit shows an arrowless popover at
/// card + 13, y 13). Losing key status — a click elsewhere — dismisses it, like a transient popover.
@MainActor
final class OrbitThemeEditorPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onCancel: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: OrbitThemeEditorMetrics.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        identifier = NSUserInterfaceItemIdentifier("orbit-theme-editor")
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// One editing session of one Space's theme.
/// Every edit is previewed at once on the presenting window (`onPreview`) and written to the store,
/// throttled, so every other window showing the Space follows live. Closing writes the final draft
/// and registers a single undo step ("Change Theme") for the whole session in the presenting
/// window's undo manager; replays are guarded by the profile and the theme they expect.
@MainActor
final class OrbitThemeEditorController {
    typealias Commit = @MainActor (BrowserSpaceTheme?) async throws -> Void
    typealias Replay = @MainActor (BrowserSpaceThemeChange) async throws -> Void

    let spaceID: SpaceID
    let profileID: ProfileID
    let view: OrbitThemeEditorView
    private(set) var panel: OrbitThemeEditorPanel?
    /// The Space's stored theme when editing began (nil: never themed).
    let original: BrowserSpaceTheme?
    private(set) var isEdited = false
    private(set) var isClosed = false
    private(set) var lastCommitted: BrowserSpaceTheme?
    private(set) var failed = false
    /// The undo step registered when the session ended (tests).
    private(set) var registeredChange: BrowserSpaceThemeChange?
    var onPreview: ((BrowserSpaceTheme) -> Void)?
    var onClosed: (() -> Void)?
    private let commit: Commit
    private let replay: Replay
    weak var registry: OrbitThemeEditorRegistry?
    private var pending: BrowserSpaceTheme?
    private var hasPending = false
    private var commitTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private weak var undoManager: UndoManager?
    private weak var undoTarget: NSWindow?

    static let scaleAnimationKey = "orbit.themeEditor.scale"
    static let opacityAnimationKey = "orbit.themeEditor.opacity"

    init(spaceID: SpaceID, profileID: ProfileID, stored: BrowserSpaceTheme?, initial: BrowserSpaceTheme,
         scopeDescription: String? = nil, commit: @escaping Commit, replay: @escaping Replay) {
        self.spaceID = spaceID
        self.profileID = profileID
        original = stored
        lastCommitted = stored
        self.commit = commit
        self.replay = replay
        view = OrbitThemeEditorView(state: OrbitThemeEditorState(theme: initial))
        if let scopeDescription {
            view.surfaceScope.stringValue = scopeDescription
            view.surfaceScope.toolTip = scopeDescription
        }
        view.onChange = { [weak self] state in self?.stateDidChange(state) }
        view.onDismiss = { [weak self] in self?.close() }
    }

    var draft: BrowserSpaceTheme { view.state.theme }

    /// The draft shown on the presenting window, once the user changed something.
    func previewTheme(for id: SpaceID?) -> BrowserSpaceTheme? {
        id == spaceID && isEdited && !failed ? draft : nil
    }

    // MARK: Presentation

    /// Shows the panel as a child of `parent`, its top-left corner at `topLeft` (parent content
    /// coordinates, top-left origin).
    func present(in parent: NSWindow, topLeft: CGPoint, animated: Bool = true) {
        guard panel == nil, !isClosed, let content = parent.contentView else { return }
        let panel = OrbitThemeEditorPanel(content: view)
        panel.appearance = OrbitAppearance.windowAppearance(for: OrbitAppearance.mode(of: draft))
        panel.onResignKey = { [weak self] in
            // A sheet or menu of the panel itself does not end editing.
            guard let self, let panel = self.panel, panel.attachedSheet == nil else { return }
            close()
        }
        panel.onCancel = { [weak self] in self?.close() }
        panel.setFrame(Self.frame(in: parent, content: content, topLeft: topLeft), display: false)
        undoManager = parent.undoManager
        undoTarget = parent
        self.panel = panel
        panel.makeFirstResponder(view.field)
        if animated { animatePresentation() }
        // A hidden parent (synthetic tests, a window being restored) never shows the editor.
        guard parent.isVisible else { return }
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Screen frame of the panel whose top-left corner is `topLeft` below the content's top edge.
    static func frame(in parent: NSWindow, content: NSView, topLeft: CGPoint) -> NSRect {
        let size = OrbitThemeEditorMetrics.size
        let contentFrame = content.frame
        let windowRect = NSRect(x: contentFrame.minX + topLeft.x, y: contentFrame.maxY - topLeft.y - size.height,
                                width: size.width, height: size.height)
        return parent.convertToScreen(windowRect)
    }

    /// : zoom from the anchor (the top-left corner, toward the sidebar) with a
    /// fade; reduced motion keeps only a short fade.
    private func animatePresentation() {
        guard let layer = view.layer else { return }
        if OrbitMotionPreferences.prefersReducedMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = OrbitTokens.Motion.reducedMotionCrossfade
            layer.add(fade, forKey: Self.opacityAnimationKey)
            return
        }
        let scale = OrbitThemeEditorMetrics.presentInitialScale
        let pivot = CGPoint(x: 0, y: layer.isGeometryFlipped ? 0 : layer.bounds.height)
        let offset = CGPoint(x: pivot.x - layer.anchorPoint.x * layer.bounds.width,
                             y: pivot.y - layer.anchorPoint.y * layer.bounds.height)
        var start = CATransform3DMakeTranslation(offset.x, offset.y, 0)
        start = CATransform3DScale(start, scale, scale, 1)
        start = CATransform3DTranslate(start, -offset.x, -offset.y, 0)
        let zoom = OrbitThemeEditorMetrics.presentScale.animation(keyPath: "transform")
        zoom.fromValue = NSValue(caTransform3D: start)
        zoom.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(zoom, forKey: Self.scaleAnimationKey)
        let fade = OrbitThemeEditorMetrics.presentOpacity.animation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        layer.add(fade, forKey: Self.opacityAnimationKey)
    }

    // MARK: Editing

    private func stateDidChange(_ state: OrbitThemeEditorState) {
        guard !isClosed, !failed else { return }
        isEdited = true
        panel?.appearance = OrbitAppearance.windowAppearance(for: OrbitAppearance.mode(of: state.theme))
        onPreview?(state.theme)
        scheduleCommit(state.theme)
    }

    private func scheduleCommit(_ theme: BrowserSpaceTheme) {
        pending = theme
        hasPending = true
        guard commitTask == nil else { return }
        commitTask = Task { [weak self] in
            while let self, self.hasPending, !self.failed {
                if !self.isClosed { try? await Task.sleep(for: OrbitThemeEditorMetrics.commitInterval) }
                await self.flushPending()
            }
            self?.commitTask = nil
        }
    }

    private func flushPending() async {
        guard hasPending, !failed else { return }
        let theme = pending
        hasPending = false
        do {
            try await commit(theme)
            lastCommitted = theme
        } catch {
            // Profile reassignment, removal or an invalid draft: stop and show the stored theme again.
            failed = true
            hasPending = false
            NSSound.beep()
            close()
        }
    }

    /// Embedded flows wait for the final persisted draft before preparing their next stage.
    func finishEditing() async {
        close(animated: false)
        await finishTask?.value
    }

    /// Ends the session: dismisses the panel, writes the final draft, then registers one undo step.
    func close(animated: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        dismissPanel(animated: animated)
        finishTask = Task { [self] in
            if hasPending, commitTask == nil { scheduleCommit(pending ?? draft) }
            await commitTask?.value
            registerUndoIfNeeded()
            onClosed?()
        }
    }

    /// Waits for the store writes and the undo registration of a closed session (tests, termination).
    func waitUntilFinished() async {
        await commitTask?.value
        await finishTask?.value
    }

    private func dismissPanel(animated: Bool) {
        guard let panel else { return }
        self.panel = nil
        panel.onResignKey = nil
        let parent = panel.parent
        let finish = {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            if parent?.isVisible == true, parent?.isMiniaturized == false { parent?.makeKey() }
        }
        guard animated, let layer = view.layer, panel.isVisible else { finish(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = OrbitThemeEditorMetrics.dismissDuration
        layer.opacity = 0
        layer.add(fade, forKey: Self.opacityAnimationKey)
        CATransaction.commit()
    }

    private func registerUndoIfNeeded() {
        guard isEdited, !failed, lastCommitted != original, let manager = undoManager, let target = undoTarget else { return }
        let change = BrowserSpaceThemeChange(spaceID: spaceID, profileID: profileID, before: original, after: lastCommitted)
        registeredChange = change
        Self.registerUndo(change, in: manager, target: target, replay: replay, registry: registry)
    }

    /// Undo replays `change.inverse`, redo `change`; a conflicting replay (theme changed elsewhere,
    /// Space reassigned to another profile or removed) changes nothing and beeps.
    /// The session's step is its own group, closed with the event (the router orders it as a window edit).
    static func registerUndo(_ change: BrowserSpaceThemeChange, in manager: UndoManager, target: NSWindow,
                             replay: @escaping Replay, registry: OrbitThemeEditorRegistry? = nil) {
        manager.beginUndoGrouping()
        register(change, in: manager, target: target, replay: replay, registry: registry)
        manager.endUndoGrouping()
    }

    private static func register(_ change: BrowserSpaceThemeChange, in manager: UndoManager, target: NSWindow,
                                 replay: @escaping Replay, registry: OrbitThemeEditorRegistry?) {
        manager.registerUndo(withTarget: target) { target in
            MainActor.assumeIsolated {
                let operation: @MainActor () async throws -> Void = { try await replay(change.inverse) }
                if let registry {
                    guard registry.enqueueReplay(operation) else { NSSound.beep(); return }
                } else {
                    Task { @MainActor in
                        do { try await operation() } catch { NSSound.beep() }
                    }
                }
                register(change.inverse, in: manager, target: target, replay: replay, registry: registry)
            }
        }
        manager.setActionName(OrbitThemeEditorText.undoAction)
    }
}

extension OrbitAppearance {
    static func mode(of theme: BrowserSpaceTheme) -> OrbitTokens.SpaceTheme.Mode {
        switch theme.mode {
        case .automatic: .automatic
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Owns active and finishing editors independently of their presenting windows. Final capture
/// freezes every entry synchronously before waiting, so a draft cannot slip past session saving.
@MainActor
final class OrbitThemeEditorRegistry {
    private struct Scope: Hashable {
        let spaceID: SpaceID
        let profileID: ProfileID
    }
    private var editors: [ObjectIdentifier: OrbitThemeEditorController] = [:]
    private var finishingScopes: Set<Scope> = []
    private(set) var isFrozen = false
    private var pendingReplay: Task<Void, Never>?

    func track(_ editor: OrbitThemeEditorController) {
        precondition(canBeginEditing(spaceID: editor.spaceID, profileID: editor.profileID))
        let id = ObjectIdentifier(editor)
        editors[id] = editor
        editor.registry = self
        let onClosed = editor.onClosed
        editor.onClosed = { [weak self] in
            onClosed?()
            self?.editors[id] = nil
        }
    }

    func canBeginEditing(spaceID: SpaceID, profileID: ProfileID) -> Bool {
        !isFrozen && !finishingScopes.contains(Scope(spaceID: spaceID, profileID: profileID))
    }

    /// Keep older full-theme drafts ahead of an independently applied field mutation. Admission
    /// stays reserved through that mutation; unrelated Spaces keep their own editing sessions.
    func withFinishedEditors(spaceID: SpaceID, profileID: ProfileID,
                             operation: @MainActor () async throws -> Void) async throws {
        let scope = Scope(spaceID: spaceID, profileID: profileID)
        guard canBeginEditing(spaceID: spaceID, profileID: profileID) else { throw BrowserSpaceThemeError.conflict }
        finishingScopes.insert(scope)
        defer { finishingScopes.remove(scope) }
        let finishing = editors.values.filter { $0.spaceID == spaceID && $0.profileID == profileID }
        for editor in finishing { editor.close(animated: false) }
        for editor in finishing { await editor.waitUntilFinished() }
        await pendingReplay?.value
        guard !isFrozen, finishing.allSatisfy({ !$0.failed }) else { throw BrowserSpaceThemeError.conflict }
        try await operation()
    }

    func finishAll() async -> Bool {
        isFrozen = true
        let finishing = Array(editors.values)
        for editor in finishing { editor.close(animated: false) }
        for editor in finishing { await editor.waitUntilFinished() }
        await pendingReplay?.value
        return finishing.allSatisfy { !$0.failed }
    }

    /// Native Undo/Redo reserves admission synchronously, before creating its asynchronous task.
    /// A final capture drains accepted replays and rejects new ones throughout disk persistence.
    func enqueueReplay(_ operation: @escaping @MainActor () async throws -> Void) -> Bool {
        guard !isFrozen else { return false }
        let previous = pendingReplay
        pendingReplay = Task {
            await previous?.value
            do { try await operation() } catch { NSSound.beep() }
        }
        return true
    }

    func thaw() { isFrozen = false }
}
