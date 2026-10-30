import AppKit
import BrowserCore

@MainActor
final class SidebarUndoRouter: NSResponder, NSUserInterfaceValidations {
    enum Source: Equatable { case organization, window }
    enum SupersessionReason: Equatable {
        case newerNativeEdit
        case externalNativeReplay
        case unstableNativeGroup
        case nativeManagerChanged
    }

    var onSuperseded: (SupersessionReason) -> Void = { _ in NSSound.beep() }
    private(set) var supersededRequestCount = 0

    var canUndoOrganization: () -> Bool = { false }
    var canRedoOrganization: () -> Bool = { false }
    /// Completion follows the session publication and identifies the record actually replayed.
    var replayOrganization: (_ redo: Bool, _ choosingOrganization: @escaping @MainActor () -> Bool,
                             _ completion: @escaping @MainActor (UInt64?) -> Void) -> Void = { _, choose, completion in
        _ = choose()
        completion(nil)
    }
    /// Menu labels of the next organization undo/redo ("Pin Tab").
    var undoOrganizationName: () -> String? = { nil }
    var redoOrganizationName: () -> String? = { nil }

    private weak var window: NSWindow?
    private weak var observedManager: UndoManager?
    /// A record's identity keeps its original place when a later record becomes unreplayable.
    /// Conflicting records remain in this timeline: the store alone decides what can be replayed.
    private enum Entry: Equatable {
        case organization(UInt64)
        case window
        var source: Source {
            if case .organization = self { return .organization }
            return .window
        }
    }
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var undoRecordID: UInt64?
    private var redoRecordID: UInt64?
    private var recordedOrganizationCount: UInt64?
    private var isForwarding = false
    /// Only newly registered native edit groups advance this generation, never FIFO replays.
    private var nativeEditGeneration: UInt64 = 0
    /// Native undo/redo outside this FIFO changes the captured history authority too.
    private var nativeReplayGeneration: UInt64 = 0
    private struct Request {
        let redo: Bool
        let prefersOrganization: Bool
        /// A text editor at receipt owns this request even if focus changes before delivery.
        let isTextFocused: Bool
        let nativeEditGeneration: UInt64
        let nativeReplayGeneration: UInt64
        let nativeManager: ObjectIdentifier?
        let hadOpenNativeGroup: Bool
    }
    private var pendingRequestCount = 0
    private var replayWaiters: [CheckedContinuation<Void, Never>] = []
    private static let depth = 200

    /// Inserts the router after `window`'s content view (idempotent; re-inserts if someone
    /// rebuilt the chain) and follows the window's undo manager.
    func install(in window: NSWindow) {
        guard let content = window.contentView else { return }
        if content.nextResponder !== self {
            nextResponder = content.nextResponder
            content.nextResponder = self
        }
        self.window = window
        guard let manager = window.undoManager, manager !== observedManager else { return }
        let center = NotificationCenter.default
        if let observedManager {
            for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                center.removeObserver(self, name: name, object: observedManager)
            }
        }
        observedManager = manager
        center.addObserver(self, selector: #selector(windowGroupDidClose(_:)), name: .NSUndoManagerDidCloseUndoGroup, object: manager)
        center.addObserver(self, selector: #selector(windowDidUndo(_:)), name: .NSUndoManagerDidUndoChange, object: manager)
        center.addObserver(self, selector: #selector(windowDidRedo(_:)), name: .NSUndoManagerDidRedoChange, object: manager)
    }

    var isInstalled: Bool { window?.contentView?.nextResponder === self }

    /// Receives the journal's actual candidates, which may jump past conflicting records without
    /// recording a new command. The counter orders new commands; identity selects the older one
    /// at its original position among window edits instead of treating it as the latest source.
    func organizationDidChange(count: UInt64, undoRecordID: UInt64?, redoRecordID: UInt64?) {
        self.undoRecordID = undoRecordID
        self.redoRecordID = redoRecordID
        defer { recordedOrganizationCount = count }
        guard let previous = recordedOrganizationCount else {
            if let undoRecordID { undoEntries.insert(.organization(undoRecordID), at: 0) }
            return
        }
        guard count > previous else { return }
        let first = max(previous + 1, count - min(count, UInt64(Self.depth)) + 1)
        for id in first...count { push(.organization(id)) }
        // A new command clears only this journal's redo side.
        redoEntries.removeAll { $0.source == .organization }
    }

    // MARK: Window undo manager

    @objc private func windowGroupDidClose(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager, !isForwarding, !manager.isUndoing, !manager.isRedoing,
              manager.groupingLevel == 0, manager.canUndo else { return }
        nativeEditGeneration &+= 1
        push(.window)
        redoEntries.removeAll { $0 == .window }
    }

    @objc private func windowDidUndo(_ notification: Notification) {
        guard !isForwarding else { return }
        nativeReplayGeneration &+= 1
        move(.window, from: &undoEntries, to: &redoEntries)
    }

    @objc private func windowDidRedo(_ notification: Notification) {
        guard !isForwarding else { return }
        nativeReplayGeneration &+= 1
        move(.window, from: &redoEntries, to: &undoEntries)
    }

    private func push(_ source: Entry) {
        undoEntries.append(source)
        if undoEntries.count > Self.depth { undoEntries.removeFirst() }
    }

    private func move(_ source: Entry, from: inout [Entry], to: inout [Entry]) {
        if let index = from.lastIndex(of: source) { from.remove(at: index) }
        to.append(source)
        if to.count > Self.depth { to.removeFirst() }
    }

    // MARK: Routing

    private var isTextFocused: Bool { window?.firstResponder is NSText }

    /// Where the next undo (or redo) goes; nil when neither source can.
    func nextSource(redo: Bool, preferringOrganization: Bool = false) -> Source? {
        resolveSource(redo: redo, preferringOrganization: preferringOrganization, textFocused: isTextFocused)
    }

    private func resolveSource(redo: Bool, preferringOrganization: Bool, textFocused: Bool) -> Source? {
        let organization = redo ? canRedoOrganization() : canUndoOrganization()
        let windowEdit = (redo ? window?.undoManager?.canRedo : window?.undoManager?.canUndo) == true
        if textFocused { return windowEdit ? .window : nil }
        if organization && (preferringOrganization || !windowEdit) { return .organization }
        if !organization { return windowEdit ? .window : nil }
        let entries = redo ? redoEntries : undoEntries
        guard let id = redo ? redoRecordID : undoRecordID,
              let organizationIndex = entries.lastIndex(of: .organization(id)) else { return .window }
        guard let windowIndex = entries.lastIndex(of: .window) else { return .organization }
        return organizationIndex > windowIndex ? .organization : .window
    }

    @objc func undo(_ sender: Any?) { perform(redo: false, sender: sender, preferringOrganization: false) }
    @objc func redo(_ sender: Any?) { perform(redo: true, sender: sender, preferringOrganization: false) }

    func perform(redo: Bool, sender: Any?, preferringOrganization: Bool) {
        let manager = window?.undoManager
        let request = Request(redo: redo, prefersOrganization: preferringOrganization, isTextFocused: isTextFocused,
                              nativeEditGeneration: nativeEditGeneration, nativeReplayGeneration: nativeReplayGeneration,
                              nativeManager: manager.map(ObjectIdentifier.init),
                              hadOpenNativeGroup: (manager?.groupingLevel ?? 0) > 0)
        pendingRequestCount += 1
        // The session reserves each accepted input immediately. Its source is resolved after the
        // previous publication, and its entry moves only after a successful replay, before the
        // next reservation. A stale snapshot can never redirect a second physical keystroke.
        replayOrganization(redo, { [weak self] in
            guard let self else { return false }
            if let reason = supersession(of: request) {
                supersededRequestCount += 1
                onSuperseded(reason)
                return false
            }
            let source = resolveSource(redo: request.redo, preferringOrganization: request.prefersOrganization,
                                       textFocused: request.isTextFocused)
            // Native validation (notably canRedo's checkpoint) may register a pending edit.
            if let reason = supersession(of: request) {
                supersededRequestCount += 1
                onSuperseded(reason)
                return false
            }
            switch source {
            case .organization?: return true
            case .window?: performWindowReplay(redo: request.redo)
            case nil: NSSound.beep()
            }
            return false
        }, { [weak self] id in
            guard let self else { return }
            if let id {
                if redo { move(.organization(id), from: &redoEntries, to: &undoEntries) }
                else { move(.organization(id), from: &undoEntries, to: &redoEntries) }
            }
            pendingRequestCount -= 1
            if pendingRequestCount == 0 {
                let waiters = replayWaiters
                replayWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        })
    }

    private func supersession(of request: Request) -> SupersessionReason? {
        let manager = window?.undoManager
        guard request.nativeManager == manager.map(ObjectIdentifier.init) else { return .nativeManagerChanged }
        guard request.nativeEditGeneration == nativeEditGeneration else { return .newerNativeEdit }
        guard request.nativeReplayGeneration == nativeReplayGeneration else { return .externalNativeReplay }
        // Public UndoManager has no immutable operation token inside an open group. Never close
        // a native/IME group here or risk undoing edits added after the physical request.
        guard !request.hadOpenNativeGroup, (manager?.groupingLevel ?? 0) == 0 else { return .unstableNativeGroup }
        return nil
    }

    private func performWindowReplay(redo: Bool) {
        guard let manager = window?.undoManager,
              (manager as? OrbitThemeUndoManager)?.allowsReplay != false else { return }
        isForwarding = true
        defer { isForwarding = false }
        if redo {
            manager.redo()
            move(.window, from: &redoEntries, to: &undoEntries)
        } else {
            manager.undo()
            move(.window, from: &undoEntries, to: &redoEntries)
        }
    }

    /// Waits for every accepted routing decision, including its replay publication.
    func waitForPendingCommands() async {
        guard pendingRequestCount > 0 else { return }
        await withCheckedContinuation { replayWaiters.append($0) }
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        validate(item, preferringOrganization: false)
    }

    func validate(_ item: any NSValidatedUserInterfaceItem, preferringOrganization: Bool) -> Bool {
        let redo: Bool
        switch item.action {
        case Selector(("undo:")): redo = false
        case Selector(("redo:")): redo = true
        default: return true
        }
        // An earlier accepted replay can create the candidate for a rapid inverse request.
        // Keep accepting input; its source will be resolved against the completed publication.
        if pendingRequestCount > 0 { return true }
        switch nextSource(redo: redo, preferringOrganization: preferringOrganization) {
        case .organization?:
            if let menuItem = item as? NSMenuItem {
                let name = (redo ? redoOrganizationName() : undoOrganizationName()) ?? ""
                let verb = redo ? SidebarUndoStrings.redo : SidebarUndoStrings.undo
                menuItem.title = name.isEmpty ? verb : uiFormat("%@ %@", verb, name)
            }
            return true
        case .window?, nil:
            // NSWindow validates against its undo manager and sets the native titles.
            return window.map { ($0 as NSUserInterfaceValidations).validateUserInterfaceItem(item) } ?? false
        }
    }
}

/// Edit-menu labels of organization commands. The menu bar is English like Orbit's (CMD).
enum SidebarUndoStrings {
    static var undo: String { uiText("Undo") }
    static var redo: String { uiText("Redo") }

    static func name(of action: BrowserOrganizationAction) -> String {
        let english: String
        switch action {
        case .moveItems: english = uiText("Move")
        case .pinTabs: english = uiText("Pin Tab")
        case .unpinTabs: english = uiText("Unpin Tab")
        case .addToFavorites: english = uiText("Add to Favorites")
        case .removeFromFavorites: english = uiText("Remove from Favorites")
        case .createFolder: english = uiText("New Folder")
        case .importBookmarks: english = uiText("Import Bookmarks")
        case .renameFolder: english = uiText("Rename Folder")
        case .deleteFolder: english = uiText("Delete Folder")
        case .renameTab: english = uiText("Rename Tab")
        case .changeTabIcon: english = uiText("Change Tab Icon")
        case .editPinnedURL: english = uiText("Edit Pinned URL")
        case .archiveTabs: english = uiText("Archive Tab")
        case .closeTabs: english = uiText("Close Tabs")
        case .clearToday: english = uiText("Clear Today")
        case .restoreArchivedTab: english = uiText("Restore Tab")
        case .deleteArchivedTabs: english = uiText("Delete Archived Tabs")
        case .createSplit: english = uiText("Create Split View")
        case .addSplitPane: english = uiText("Add Split Pane")
        case .closeSplitPane: english = uiText("Close Split Pane")
        case .unsplit: english = uiText("Unsplit All Tabs")
        case .orientSplit: english = uiText("Change Split Orientation")
        case .swapSplitPanes: english = uiText("Swap Split Panes")
        case .resizeSplit: english = uiText("Resize Split View")
        }
        return english
    }
}
