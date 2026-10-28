import Foundation

/// An engine capability failure is distinct from an authoritative no-match result.
public enum BrowserFindError: Error, Equatable, Sendable {
    case unsupportedOperation
}

public struct BrowserFindRequest: Equatable, Sendable {
    public let token: UUID
    public let documentGeneration: UInt64
    public let query: String
    public let forward: Bool
    public let matchCase: Bool
    /// False requests counting without selecting or scrolling. Unsupported engines must reject it.
    public let selectMatch: Bool

    public init(
        token: UUID, documentGeneration: UInt64, query: String,
        forward: Bool, matchCase: Bool, selectMatch: Bool
    ) {
        self.token = token
        self.documentGeneration = documentGeneration
        self.query = query
        self.forward = forward
        self.matchCase = matchCase
        self.selectMatch = selectMatch
    }
}

/// Nil totals and ordinals mean unknown, including on a final result. A Boolean is never a count.
/// Within one operation, partial totals are cumulative. Engines normalize their unknown sentinels
/// to nil. An error must be final, with matchFound false and both numeric fields nil.
public struct BrowserFindUpdate: Equatable, Sendable {
    public let token: UUID
    public let documentGeneration: UInt64
    public let matchFound: Bool
    public let count: Int?
    /// Zero explicitly means no selected match; it is valid for a positive count-only result.
    public let activeOrdinal: Int?
    public let final: Bool
    public let error: BrowserFindError?

    public init(
        token: UUID, documentGeneration: UInt64, matchFound: Bool,
        count: Int? = nil, activeOrdinal: Int? = nil, final: Bool,
        error: BrowserFindError? = nil
    ) {
        self.token = token
        self.documentGeneration = documentGeneration
        self.matchFound = matchFound
        self.count = count
        self.activeOrdinal = activeOrdinal
        self.final = final
        self.error = error
    }
}

@MainActor
public protocol BrowserFindSurface: BrowserSurface {
    /// The adapter advances this before exposing a different document, including same-URL reloads.
    var findDocumentGeneration: UInt64 { get }
    func performFind(
        _ request: BrowserFindRequest,
        update: @escaping @MainActor (BrowserFindUpdate) -> Void
    )
    func stopFinding(clearSelection: Bool)
}

/// A value snapshot, never persisted or shared with another surface or window.
public struct BrowserFindState: Equatable, Sendable {
    public internal(set) var query = ""
    public internal(set) var matchCase = false
    public internal(set) var documentGeneration: UInt64
    public internal(set) var isVisible = false
    public internal(set) var isPending = false
    /// Nil means that no successful engine report has established even a Boolean result.
    public internal(set) var matchFound: Bool?
    public internal(set) var count: Int?
    public internal(set) var activeOrdinal: Int?
    public internal(set) var isFinal = false
    public internal(set) var error: BrowserFindError?

    public var hasExactCount: Bool { isFinal && error == nil && count != nil }

    fileprivate init(documentGeneration: UInt64) {
        self.documentGeneration = documentGeneration
    }

    fileprivate mutating func clearResult(documentGeneration: UInt64) {
        self.documentGeneration = documentGeneration
        isPending = false
        matchFound = nil
        count = nil
        activeOrdinal = nil
        isFinal = false
        error = nil
    }
}

/// Coordinates engine find operations without owning surfaces, mutating a browser store, using a
/// system find pasteboard, scanning documents, or retaining queries after surface retirement.
/// The window coordinator remains responsible for ordering selection and navigation effects.
@MainActor
public final class BrowserFindSession<Surface: BrowserFindSurface> {
    public var onChange: (() -> Void)?
    /// The UI restores focus to this exact surface after closing its bar, if it is still selected.
    public var onFocusReturn: ((Surface) -> Void)?
    public private(set) var isClosed = false
    public private(set) weak var selectedSurface: Surface?

    @MainActor
    private final class Entry {
        weak var surface: Surface?
        var state: BrowserFindState
        var revision = UUID()
        var request: BrowserFindRequest?
        var queuedDirection: Bool?
        var hasNativeWork = false
        var requiresStop = false
        var clearSelectionOnStop = true

        init(_ surface: Surface) {
            self.surface = surface
            state = BrowserFindState(documentGeneration: surface.findDocumentGeneration)
        }
    }

    @MainActor
    private final class RetiredSurface {
        weak var surface: Surface?
        init(_ surface: Surface) { self.surface = surface }
    }

    private enum Effect {
        case stop(Entry, revision: UUID, clearSelection: Bool)
        case find(Entry, revision: UUID, request: BrowserFindRequest)
        case focus(Entry, revision: UUID, selection: UUID)
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    // Weak tombstones prevent a reentrant adapter from readopting an already retired object.
    private var retired: [ObjectIdentifier: RetiredSurface] = [:]
    private var selectionRevision = UUID()
    private var effects: [Effect] = []
    private var isDrainingEffects = false

    public init() {}

    public var state: BrowserFindState? {
        selectedSurface.flatMap { state(for: $0) }
    }

    public func state(for surface: Surface) -> BrowserFindState? {
        pruneDeadSurfaces()
        guard !isClosed, let entry = entries[ObjectIdentifier(surface)],
              entry.surface === surface else { return nil }
        var state = entry.state
        // Even if an adapter missed its explicit notification, old document results are not shown.
        if state.documentGeneration != surface.findDocumentGeneration {
            state.clearResult(documentGeneration: surface.findDocumentGeneration)
        }
        return state
    }

    /// Selection only publishes cached state. It never performs a search or transfers a query.
    public func select(_ surface: Surface?) {
        guard !isClosed else { return }
        pruneDeadSurfaces()
        if let surface {
            guard let entry = entry(for: surface) else { return }
            let documentChanged = synchronizeDocument(entry, surface: surface)
            let selectionChanged = selectedSurface !== surface
            selectedSurface = surface
            if selectionChanged { selectionRevision = UUID() }
            if selectionChanged || documentChanged { onChange?() }
        } else if selectedSurface != nil {
            selectedSurface = nil
            selectionRevision = UUID()
            onChange?()
        }
    }

    public func show(on surface: Surface) {
        guard !isClosed, let entry = entry(for: surface) else { return }
        let documentChanged = synchronizeDocument(entry, surface: surface)
        let selectionChanged = selectedSurface !== surface
        let visibilityChanged = !entry.state.isVisible
        selectedSurface = surface
        if selectionChanged { selectionRevision = UUID() }
        entry.state.isVisible = true
        if selectionChanged || visibilityChanged || documentChanged { onChange?() }
    }

    /// Reopening a bar preserves its query but does not select or scroll a match.
    public func show() {
        guard !isClosed, let surface = selectedSurface else { return }
        show(on: surface)
    }

    /// An explicit submission refreshes against the living document, even for the same query.
    /// Empty strings clear the operation. Whitespace remains a valid literal query.
    public func submit(_ query: String, matchCase: Bool = false, selectMatch: Bool = true) {
        guard !isClosed, let surface = selectedSurface, let entry = entry(for: surface) else { return }
        begin(
            entry, surface: surface, query: query, matchCase: matchCase,
            forward: true, selectMatch: selectMatch, cancelPrevious: true
        )
    }

    public func next() { move(forward: true) }
    public func previous() { move(forward: false) }

    /// Closes only the selected bar, retaining that surface's query for a later explicit Cmd-G.
    public func close(clearSelection: Bool = true, returnFocus: Bool = true) {
        guard !isClosed, let surface = selectedSurface,
              let entry = entries[ObjectIdentifier(surface)], entry.surface === surface else { return }
        defer { drainEffects() }
        invalidate(entry, documentGeneration: surface.findDocumentGeneration)
        entry.state.isVisible = false
        scheduleStop(entry, clearSelection: clearSelection)
        if returnFocus {
            effects.append(.focus(entry, revision: entry.revision, selection: selectionRevision))
        }
        publish(entry)
    }

    /// Invalidates immediately; the adapter decides when the new document is ready to resubmit.
    /// Neither navigation nor selecting a previously inactive Space implicitly scrolls a match.
    public func documentDidChange(on surface: Surface) {
        guard !isClosed, let entry = entries[ObjectIdentifier(surface)],
              entry.surface === surface else { return }
        defer { drainEffects() }
        invalidate(entry, documentGeneration: surface.findDocumentGeneration)
        scheduleStop(entry, clearSelection: true)
        publish(entry)
    }

    /// Removes all query and result state before the adapter receives its stop callback.
    public func retire(_ surface: Surface) {
        guard !isClosed else { return }
        defer { drainEffects() }
        pruneDeadSurfaces()
        let id = ObjectIdentifier(surface)
        retired[id] = RetiredSurface(surface)
        let entry = entries.removeValue(forKey: id)
        if let entry, entry.surface === surface {
            invalidate(entry, documentGeneration: surface.findDocumentGeneration)
            entry.state = BrowserFindState(documentGeneration: surface.findDocumentGeneration)
            scheduleStop(entry, clearSelection: true)
        }
        if selectedSurface === surface {
            selectedSurface = nil
            selectionRevision = UUID()
            onChange?()
        }
    }

    /// Permanently revokes this window's callbacks before stopping any of its engines.
    public func shutdown() {
        guard !isClosed else { return }
        defer { drainEffects() }
        isClosed = true
        selectedSurface = nil
        selectionRevision = UUID()
        let oldEntries = Array(entries.values)
        entries.removeAll()
        retired.removeAll()
        for entry in oldEntries {
            invalidate(entry, documentGeneration: entry.state.documentGeneration)
            entry.state = BrowserFindState(documentGeneration: entry.state.documentGeneration)
            scheduleStop(entry, clearSelection: true)
        }
        onChange?()
    }

    private func pruneDeadSurfaces() {
        entries = entries.filter { $0.value.surface != nil }
        retired = retired.filter { $0.value.surface != nil }
    }

    private func entry(for surface: Surface) -> Entry? {
        pruneDeadSurfaces()
        let id = ObjectIdentifier(surface)
        guard retired[id]?.surface !== surface else { return nil }
        if let entry = entries[id], entry.surface === surface { return entry }
        let entry = Entry(surface)
        entries[id] = entry
        return entry
    }

    @discardableResult
    private func synchronizeDocument(_ entry: Entry, surface: Surface) -> Bool {
        guard entry.state.documentGeneration != surface.findDocumentGeneration else { return false }
        invalidate(entry, documentGeneration: surface.findDocumentGeneration)
        // Selection itself has no native effects, but the next explicit operation must cancel
        // any old-document engine work, even when this metadata was already synchronized.
        entry.requiresStop = true
        entry.clearSelectionOnStop = true
        return true
    }

    private func invalidate(_ entry: Entry, documentGeneration: UInt64) {
        entry.revision = UUID()
        entry.request = nil
        entry.queuedDirection = nil
        entry.state.clearResult(documentGeneration: documentGeneration)
    }

    private func isLive(_ entry: Entry, surface: Surface) -> Bool {
        !isClosed && entries[ObjectIdentifier(surface)] === entry && entry.surface === surface
    }

    private func publish(_ entry: Entry) {
        if let surface = entry.surface, isLive(entry, surface: surface), selectedSurface === surface {
            onChange?()
        }
    }

    private func scheduleStop(_ entry: Entry, clearSelection: Bool) {
        entry.requiresStop = true
        entry.clearSelectionOnStop = clearSelection
        effects.append(.stop(entry, revision: entry.revision, clearSelection: clearSelection))
    }

    private func begin(
        _ entry: Entry, surface: Surface, query: String, matchCase: Bool,
        forward: Bool, selectMatch: Bool, cancelPrevious: Bool
    ) {
        defer { drainEffects() }
        invalidate(entry, documentGeneration: surface.findDocumentGeneration)
        entry.state.query = query
        entry.state.matchCase = matchCase
        if cancelPrevious {
            scheduleStop(entry, clearSelection: true)
        } else if entry.requiresStop {
            // A reentrant movement may supersede a queued close/document stop. Carry its
            // cancellation forward instead of accidentally preserving the previous cursor.
            scheduleStop(entry, clearSelection: entry.clearSelectionOnStop)
        }
        if !query.isEmpty {
            let request = BrowserFindRequest(
                token: UUID(), documentGeneration: surface.findDocumentGeneration,
                query: query, forward: forward, matchCase: matchCase, selectMatch: selectMatch
            )
            entry.request = request
            entry.state.isPending = true
            effects.append(.find(entry, revision: entry.revision, request: request))
        }
        publish(entry)
    }

    private func move(forward: Bool) {
        guard !isClosed, let surface = selectedSurface, let entry = entry(for: surface),
              !entry.state.query.isEmpty else { return }
        let documentChanged = synchronizeDocument(entry, surface: surface)
        if entry.state.isPending {
            // At most one follow-up survives while an engine is computing its initial result.
            entry.queuedDirection = forward
            return
        }
        begin(
            entry, surface: surface, query: entry.state.query, matchCase: entry.state.matchCase,
            forward: forward, selectMatch: true, cancelPrevious: documentChanged
        )
    }

    private func receive(
        _ update: BrowserFindUpdate, from surface: Surface, entry: Entry,
        token: UUID, documentGeneration: UInt64
    ) {
        guard isLive(entry, surface: surface), entry.request?.token == token,
              update.token == token, update.documentGeneration == documentGeneration,
              surface.findDocumentGeneration == documentGeneration,
              entry.state.documentGeneration == documentGeneration,
              entry.state.isPending, let request = entry.request,
              valid(update, for: request, previous: entry.state) else { return }
        let revision = entry.revision
        entry.state.isPending = !update.final
        entry.state.isFinal = update.final
        entry.state.error = update.error
        entry.state.matchFound = update.error == nil ? update.matchFound : nil
        entry.state.count = update.count
        entry.state.activeOrdinal = update.activeOrdinal
        let direction = update.final ? entry.queuedDirection : nil
        if update.final { entry.queuedDirection = nil }
        publish(entry)
        guard update.final, update.error == nil, let direction,
              isLive(entry, surface: surface), entry.revision == revision,
              entry.request?.token == token, surface.findDocumentGeneration == documentGeneration else { return }
        begin(
            entry, surface: surface, query: request.query, matchCase: request.matchCase,
            forward: direction, selectMatch: true, cancelPrevious: false
        )
    }

    private func valid(
        _ update: BrowserFindUpdate, for request: BrowserFindRequest, previous: BrowserFindState
    ) -> Bool {
        if update.error != nil {
            return update.final && !update.matchFound && update.count == nil && update.activeOrdinal == nil
        }
        if let count = update.count {
            guard count >= 0, (count > 0) == update.matchFound else { return false }
            if let oldCount = previous.count, count < oldCount { return false }
        } else if previous.count != nil && !update.final {
            return false
        }
        if let ordinal = update.activeOrdinal {
            guard ordinal >= 0, ordinal == 0 || update.matchFound else { return false }
            if let count = update.count, ordinal > count { return false }
            if !request.selectMatch && ordinal > 0 { return false }
            if let oldOrdinal = previous.activeOrdinal, oldOrdinal > 0 && ordinal == 0 { return false }
        }
        if previous.matchFound == true && !update.matchFound { return false }
        return true
    }

    /// Native calls never nest, even when engine reports and UI observers are synchronous.
    /// Reentrant intent changes revoke queued effects before they can touch an engine.
    private func drainEffects() {
        guard !isDrainingEffects else { return }
        isDrainingEffects = true
        defer { isDrainingEffects = false }
        while !effects.isEmpty {
            let effect = effects.removeFirst()
            switch effect {
            case let .stop(entry, revision, clearSelection):
                guard entry.revision == revision, let surface = entry.surface, entry.requiresStop else { continue }
                entry.requiresStop = false
                guard entry.hasNativeWork else { continue }
                entry.hasNativeWork = false
                surface.stopFinding(clearSelection: clearSelection)
            case let .find(entry, revision, request):
                guard let surface = entry.surface, isLive(entry, surface: surface),
                      entry.revision == revision, entry.request?.token == request.token,
                      entry.state.isPending else { continue }
                guard surface.findDocumentGeneration == request.documentGeneration else {
                    documentDidChange(on: surface)
                    continue
                }
                entry.hasNativeWork = true
                let token = request.token
                let generation = request.documentGeneration
                surface.performFind(request) { [weak self, weak surface, weak entry] update in
                    guard let self, let surface, let entry else { return }
                    self.receive(update, from: surface, entry: entry, token: token, documentGeneration: generation)
                    self.drainEffects()
                }
            case let .focus(entry, revision, selection):
                guard let surface = entry.surface, isLive(entry, surface: surface),
                      entry.revision == revision, selectionRevision == selection,
                      selectedSurface === surface, !entry.state.isVisible,
                      surface.findDocumentGeneration == entry.state.documentGeneration else { continue }
                onFocusReturn?(surface)
            }
        }
    }
}
