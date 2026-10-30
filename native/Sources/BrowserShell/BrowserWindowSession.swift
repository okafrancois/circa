import BrowserCore
import Foundation

/// A live engine surface, owned and retired on the UI executor.
@MainActor
public protocol BrowserSurface: AnyObject {
    var currentURL: URL? { get }
    func dispose()
    /// Keeps the engine's session controller while releasing its renderer. A refusal must
    /// never fall back to URL replay, which would destroy opaque history and POST state.
    func suspendInPlace() -> BrowserSurfaceSuspensionResult
}

public enum BrowserSurfaceSuspensionResult { case unsupported, refused, suspended }

public extension BrowserSurface {
    func suspendInPlace() -> BrowserSurfaceSuspensionResult { .unsupported }
}

public enum BrowserWindowSessionError: Error, Equatable {
    case contextChangeRequiresNewSession
    case surfaceNotOwned
    /// The surface factory could not create a surface, for example because its owner is gone.
    case surfaceUnavailable
}

/// A thread-safe, one-way authorization for a pending automatic selection.
/// Revocation prevents a future model commit; it never rolls back an already committed selection.
public final class BrowserSelectionIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    public init() {}
    public var isRevoked: Bool { lock.withLock { revoked } }
    public func revoke() { lock.withLock { revoked = true } }

    /// Only the callback-free model transaction in this file may execute while the lock is held.
    fileprivate func whileActive<Value>(_ action: () throws -> Value) rethrows -> Value? {
        try lock.withLock {
            guard !revoked else { return nil }
            return try action()
        }
    }
}

/// Retries of one command after organization changes made by other windows; each retry follows a
/// change the store vouched for, so the bound only stops a pathological stream of such changes.
let maximumOrganizationAdoptions = 4

/// Serializes synchronous retirement with the short, callback-free model transactions below.
/// No engine surface or UI state crosses executors; only this lock-protected revocation bit does.
final class SurfaceCommandLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true

    func revoke() { lock.withLock { isActive = false } }

    func whileActive<Value>(_ action: () throws -> Value) rethrows -> Value? {
        try lock.withLock {
            guard isActive else { return nil }
            return try action()
        }
    }
}

/// Provenance is shared by every owner, including sessions with different Surface specializations,
/// feature containers and transfers in flight. Weak identities retain neither the engine instance
/// nor its owner after their own lifetimes end.
@MainActor
enum BrowserSurfaceProvenance {
    final class Record {
        enum State { case reserved, owned, retiring, disposed }

        weak var surface: AnyObject?
        weak var owner: AnyObject?
        var state: State
        var wasDisposed = false
        let lifetime = SurfaceCommandLifetime()

        init(surface: any BrowserSurface, owner: AnyObject, state: State) {
            self.surface = surface
            self.owner = owner
            self.state = state
        }
    }

    private static var records: [ObjectIdentifier: Record] = [:]
    private static var insertions = 0

    static func reserve(_ surface: any BrowserSurface, for owner: AnyObject) -> Record? {
        guard record(for: surface) == nil else { return nil }
        return insert(surface, owner: owner, state: .reserved)
    }

    static func registerFactorySurface(_ surface: any BrowserSurface, for owner: AnyObject) -> Bool {
        guard record(for: surface) == nil else { return false }
        _ = insert(surface, owner: owner, state: .owned)
        return true
    }

    static func isHeld(_ surface: any BrowserSurface, by owner: AnyObject) -> Bool {
        guard let record = record(for: surface), record.owner === owner, !record.wasDisposed else { return false }
        return record.state == .owned || record.state == .reserved
    }

    /// Moves a held surface to `newOwner` in one step, without disposal. The previous record is
    /// revoked, so commands that captured it fail; the new owner starts in `state`.
    static func handOff(
        _ surface: any BrowserSurface, from owner: AnyObject, to newOwner: AnyObject, state: Record.State
    ) -> Record? {
        guard isHeld(surface, by: owner), let previous = record(for: surface) else { return nil }
        previous.state = .retiring
        previous.lifetime.revoke()
        return insert(surface, owner: newOwner, state: state)
    }

    static func ownedRecord(for surface: any BrowserSurface, owner: AnyObject) -> Record? {
        guard let record = record(for: surface), record.owner === owner,
              record.state == .owned, !record.wasDisposed else { return nil }
        return record
    }

    static func isReserved(_ record: Record, surface: any BrowserSurface, for owner: AnyObject) -> Bool {
        record.surface === surface && record.owner === owner && record.state == .reserved && !record.wasDisposed
    }

    static func bind(_ record: Record, surface: any BrowserSurface, to owner: AnyObject) -> Bool {
        guard isReserved(record, surface: surface, for: owner) else { return false }
        record.state = .owned
        return true
    }

    static func revoke(_ surface: any BrowserSurface, ownedBy owner: AnyObject) {
        guard let record = record(for: surface), record.owner === owner, !record.wasDisposed else { return }
        record.state = .retiring
        record.lifetime.revoke()
    }

    static func dispose(_ surface: any BrowserSurface, ownedBy owner: AnyObject) {
        guard let record = record(for: surface), record.owner === owner, !record.wasDisposed else { return }
        revoke(surface, ownedBy: owner)
        record.wasDisposed = true
        record.state = .disposed
        // Keep ownership and the terminal disposition visible throughout reentrant callbacks.
        surface.dispose()
        record.owner = nil
    }

    private static func record(for surface: any BrowserSurface) -> Record? {
        let identity = ObjectIdentifier(surface)
        guard let record = records[identity] else { return nil }
        guard record.surface === surface else {
            records.removeValue(forKey: identity)
            return nil
        }
        return record
    }

    private static func insert(_ surface: any BrowserSurface, owner: AnyObject, state: Record.State) -> Record {
        insertions += 1
        if insertions == 64 {
            records = records.filter { $0.value.surface != nil }
            insertions = 0
        }
        let record = Record(surface: surface, owner: owner, state: state)
        records[ObjectIdentifier(surface)] = record
        return record
    }
}

private extension BrowserStore {
    /// Inventory validation and background creation share one actor turn. A background source can
    /// disappear without changing selection authority, so checking the context alone is insufficient.
    func openProvidedSurfaceTab(
        url: URL, from context: BrowserContext, source: BrowserOccurrenceAuthority,
        lifetime: SurfaceCommandLifetime, providedLifetime: SurfaceCommandLifetime
    ) throws -> (TabOccurrenceID, BrowserWindowState)? {
        try lifetime.whileActive { () throws -> (TabOccurrenceID, BrowserWindowState)? in
            try providedLifetime.whileActive { () throws -> (TabOccurrenceID, BrowserWindowState)? in
                let before = try captureWindowState(from: context)
                guard source.windowID == context.windowID, source.spaceID == context.spaceID,
                      source.profileID == context.profileID,
                      before.occurrenceAuthorities[source.occurrenceID] == source else { return nil }
                let occurrenceID = try openTab(url: url, from: context, activate: false)
                return (occurrenceID, try captureWindowState(from: context))
            } ?? nil
        } ?? nil
    }

    func selectProvidedSurfaceTab(
        _ authority: BrowserOccurrenceAuthority, ifContextMatches context: BrowserContext,
        lifetime: SurfaceCommandLifetime, targetLifetime: SurfaceCommandLifetime,
        intent: BrowserSelectionIntent, state: BrowserWindowState?, index: BrowserOrganizationMetadataIndex?
    ) throws -> BrowserWindowState? {
        try lifetime.whileActive { () throws -> BrowserWindowState? in
            try targetLifetime.whileActive { () throws -> BrowserWindowState? in
                // Lock order is always session, target, intent. No UI or engine callback runs here.
                try intent.whileActive { () throws -> BrowserWindowState? in
                    guard authority.windowID == context.windowID, authority.spaceID == context.spaceID,
                          authority.profileID == context.profileID,
                          try captureOccurrenceAuthority(for: authority.occurrenceID, from: context) == authority else { return nil }
                    return try selectOccurrenceUpdating(authority.occurrenceID, from: context, state: state, index: index)
                } ?? nil
            } ?? nil
        } ?? nil
    }

    func closeOwnedSurfaceTab(
        _ authority: BrowserOccurrenceAuthority, validating context: BrowserContext,
        lifetime: SurfaceCommandLifetime, targetLifetime: SurfaceCommandLifetime
    ) throws -> BrowserWindowState? {
        try lifetime.whileActive { () throws -> BrowserWindowState? in
            try targetLifetime.whileActive {
                try closeOwnedOccurrenceAndCaptureState(authority, validating: context)
            }
        } ?? nil
    }
}

/// Serializes window commands while retaining live surfaces across Space and profile changes.
@MainActor
public final class BrowserWindowSession<Surface: BrowserSurface> {
    /// Product windows materialize only the selected tab and its visible Split peers. Eager
    /// remains available to non-UI clients that intentionally prepare a whole Space.
    public enum SurfaceLoadingPolicy { case eager, visibleOnly }
    public var surfaceLoadingPolicy: SurfaceLoadingPolicy = .eager
    private var requestedSurfaceIDs: Set<TabOccurrenceID> = []
    /// Only the active Space is represented here. Inactive surfaces remain in ownedSurfaces.
    public private(set) var snapshot: BrowserWindowSnapshot?
    public private(set) var catalog: BrowserCatalogSnapshot?
    public private(set) var isClosed = false
    public var onChange: (() -> Void)?
    public var usesScopedSelectionUpdates = true
    /// Valid only while the existing onChange publication is being delivered.
    public private(set) var selectionChangeTabIDs: Set<TabID>?
    public var onMetadataChange: ((Set<TabID>) -> Void)?
    public var onError: ((any Error) -> Void)?

    let store: BrowserStore
    /// Nil when the owner of the factory is gone; the occurrence then stays without a surface.
    let makeSurface: (ProfileID, URL) -> Surface?
    /// Starts the first load of a factory surface once ownership is recorded. Nil for factories
    /// that load by themselves.
    let startSurface: ((Surface, URL) -> Void)?
    /// Called synchronously whenever this session starts recording a surface as one of its
    /// occurrences (factory creation, adoption, accepted transfer), before any load starts, and
    /// with nil when the surface leaves the session alive through `releaseSurface`.
    public var onSurfaceMembershipChange: ((Surface, BrowserSurfaceMembership?) -> Void)?
    var windowID: WindowID?
    var activeContext: BrowserContext?
    var surfaces: [TabOccurrenceID: Surface] = [:]
    var surfaceOrder: [TabOccurrenceID] = []
    var occurrencesBySurface: [ObjectIdentifier: TabOccurrenceID] = [:]
    var authorities: [TabOccurrenceID: BrowserOccurrenceAuthority] = [:]
    /// Complete model leases, including restored inactive occurrences not yet materialized.
    var modelOccurrenceAuthorities: [TabOccurrenceID: BrowserOccurrenceAuthority] = [:]
    var occurrenceTabIDs: [TabOccurrenceID: TabID] = [:]
    var pending: Task<Void, Never>?
    /// Placeholders of live surfaces released through `releaseSurface` and still in flight, or
    /// recorded elsewhere and awaiting release; never recreated by the factory.
    var transits: [TabOccurrenceID: SurfaceTransit<Surface>] = [:]
    /// Where surfaces released from this window go when their move fails after this window
    /// closed or lost their placeholder. Nil leaves them to the stranded registry.
    public var rescueContainer: BrowserSurfaceContainer<Surface>?
    var pendingCommandCount = 0
    var spaceSettingsActions: [UUID: BrowserSpaceSettingsAuthority] = [:]
    /// Prevents reciprocal batch receptions from waiting on each other's reserved source cleanup.
    var splitReleaseReservationCount = 0
    let surfaceCommandLifetime = SurfaceCommandLifetime()
    var bookmarkAdmissions: [UUID: BrowserBookmarkImportAdmission] = [:]
    var bookmarkTransferCancellations: [UUID: @MainActor () -> Void] = [:]
    var acceptedBookmarkExports: [UUID: Task<Void, Error>] = [:]
    /// Sidebar snapshot and cross-window observation; see BrowserWindowSession+Organization.swift.
    let organizationRuntime = BrowserOrganizationSessionRuntime()

    /// `makeSurface` creates a surface for a model tab, or returns nil when it no longer can (its
    /// owner is gone): the session then reports `surfaceUnavailable` and leaves the tab without a
    /// surface. With `startSurface`, the factory must not load: the session records ownership,
    /// reports membership, then calls `startSurface` with the tab's URL, so synchronous engine
    /// events reach an owner that already knows the surface.
    public init(
        store: BrowserStore = BrowserStore(),
        spaceID: SpaceID? = nil,
        makeSurface: @escaping (ProfileID, URL) -> Surface?,
        startSurface: ((Surface, URL) -> Void)? = nil
    ) {
        self.store = store
        self.makeSurface = makeSurface
        self.startSurface = startSurface
        enqueue { session in
            let initialSpaceID: SpaceID
            if let spaceID {
                initialSpaceID = spaceID
            } else {
                let profileID = await store.createProfile(name: BrowserText.string("Personal"))
                guard !session.isClosed else { return }
                initialSpaceID = try await store.createSpace(name: BrowserText.string("Personal"), profileID: profileID)
            }
            guard !session.isClosed else { return }
            let windowID = try await store.createWindow(activeSpaceID: initialSpaceID)
            // Retain ownership even if close() ran during this actor hop.
            session.windowID = windowID
            try await session.adoptWindow(windowID)
        }
    }

    /// Restores the active Space once. Other Spaces acquire surfaces only on first activation.
    public init(
        store: BrowserStore,
        restoringWindowID: WindowID,
        makeSurface: @escaping (ProfileID, URL) -> Surface?,
        startSurface: ((Surface, URL) -> Void)? = nil
    ) {
        self.store = store
        self.makeSurface = makeSurface
        self.startSurface = startSurface
        windowID = restoringWindowID
        enqueue { session in
            try await session.adoptWindow(restoringWindowID)
        }
    }

    /// The profile of the active Space, nil before the window is adopted or after closure.
    public var activeProfileID: ProfileID? { isClosed ? nil : activeContext?.profileID }

    public var selectedSurface: Surface? {
        guard let occurrenceID = snapshot?.selectedOccurrenceID else { return nil }
        return surfaces[occurrenceID]
    }

    /// Every live surface owned by this window, in acquisition order, including inactive Spaces.
    public var ownedSurfaces: [Surface] { surfaceOrder.compactMap { surfaces[$0] } }
    public var hasPendingCommands: Bool { pendingCommandCount > 0 }
    public var canReopenClosedTab: Bool {
        !isClosed && organization?.canRestoreArchivedTab == true
    }

    public func tabID(for occurrenceID: TabOccurrenceID) -> TabID? { occurrenceTabIDs[occurrenceID] }

    public func surface(for occurrenceID: TabOccurrenceID) -> Surface? { surfaces[occurrenceID] }

    public func occurrenceID(for surface: Surface) -> TabOccurrenceID? {
        guard !isClosed, let id = occurrencesBySurface[ObjectIdentifier(surface)],
              surfaces[id] === surface else { return nil }
        return id
    }

    public func holds(_ surface: Surface) -> Bool {
        !isClosed && BrowserSurfaceProvenance.isHeld(surface, by: self)
    }

    public func activateSpace(_ spaceID: SpaceID) {
        enqueue { session in
            try await session.withAdoptedContext { context in
                let state = try await session.store.activateSpace(spaceID, from: context)
                session.install(state)
            }
        }
    }

    /// Resolves relative movement in queue order against the current shared catalog.
    public func activateAdjacentSpace(offset: Int) {
        enqueue { session in
            try await session.withAdoptedContext { context in
                let state = try await session.store.activateAdjacentSpace(offset: offset, from: context)
                session.install(state)
            }
        }
    }

    /// Creates an empty Space in the explicit profile and activates it in command order.
    public func createSpace(name: String, profileID: ProfileID) {
        enqueue { session in
            try await session.withAdoptedContext { context in
                let state = try await session.store.createSpace(name: name, profileID: profileID, from: context)
                session.install(state)
            }
        }
    }

    public func createSpace(name: String, newProfileName: String) {
        enqueue { session in
            try await session.withAdoptedContext { context in
                let state = try await session.store.createSpace(name: name, newProfileName: newProfileName, from: context)
                session.install(state)
            }
        }
    }

    /// Create with its appearance before publishing, so the first visible frame is complete.
    public func createSpace(name: String, profileID: ProfileID?, newProfileName: String?,
                            theme: BrowserSpaceTheme, icon: BrowserSpaceIcon, settings: BrowserSettingsStore?,
                            beforePublication: @escaping @MainActor () async -> Void = {},
                            completion: @escaping @MainActor (Bool) -> Void) {
        enqueue { session in
            do {
                try theme.validate()
                guard icon.isValid else { throw BrowserSettingsError.invalidIcon }
                guard settings?.isUnavailable != true else { throw BrowserSettingsError.unavailable }
                try await session.withAdoptedContext { context in
                    let state: BrowserWindowState
                    if let profileID {
                        state = try await session.store.createSpace(name: name, profileID: profileID, from: context)
                    } else if let newProfileName {
                        state = try await session.store.createSpace(name: name, newProfileName: newProfileName, from: context)
                    } else { throw BrowserStoreError.profileMissing }
                    let id = state.snapshot.activeSpaceID
                    guard let space = state.catalog.spaces.first(where: { $0.id == id }) else { throw BrowserStoreError.spaceMissing }
                    _ = try await session.store.setSpaceTheme(theme, for: id, profileID: space.profileID)
                    try await settings?.updateSpace(id) { $0.iconSelection = icon }
                    await beforePublication()
                    session.install(try await session.store.captureWindowState(in: context.windowID))
                }
                completion(true)
            } catch { completion(false); throw error }
        }
    }

    /// A removed Space revokes the old context; adopt its model-selected fallback in queue order.
    public func refreshAfterSpaceRemoval(_ spaceID: SpaceID) {
        enqueue { session in
            guard let windowID = session.windowID else { return }
            let state = try await session.store.captureWindowState(in: windowID)
            guard !state.catalog.spaces.contains(where: { $0.id == spaceID }), !session.isClosed else { return }
            session.install(state)
        }
    }

    /// Explicit adoption after a profile move. Ordinary queued commands still reject the old
    /// context; install disposes revoked surfaces before loading pages in the target profile.
    public func refreshAfterSpaceProfileMove() {
        enqueue { session in
            guard let windowID = session.windowID else { return }
            let state = try await session.store.captureWindowState(in: windowID)
            guard !session.isClosed else { return }
            session.install(state)
        }
    }

    public func renameSpace(_ spaceID: SpaceID, name: String) {
        enqueue { session in
            // Idempotent: a retry after the rename only renames again.
            try await session.withAdoptedContext { context in
                try await session.store.renameSpace(spaceID, name: name, from: context)
                try await session.refreshCatalog(from: context)
            }
        }
    }

    public func moveSpace(_ spaceID: SpaceID, before destination: SpaceID?) {
        enqueue { session in
            try await session.withAdoptedContext { context in
                try await session.store.moveSpace(spaceID, before: destination, from: context)
                try await session.refreshCatalog(from: context)
            }
        }
    }

    /// Refreshes shared catalog changes without rebinding this window's active authority.
    /// An unchanged catalog does not publish, avoiding cross-window refresh loops.
    public func refreshCatalog() {
        enqueue { session in
            try await session.withAdoptedContext { context in try await session.refreshCatalog(from: context) }
        }
    }

    public func openTab(url: URL = URL(string: "about:blank")!, activate: Bool = true) {
        enqueue { session in
            try await session.createTab(url: url, activate: activate)
        }
    }

    /// A native presentation cannot retarget creation after queued Space/profile selection.
    public func openTab(url: URL, from context: BrowserContext) {
        enqueue { session in
            guard session.activeContext == context else { return }
            try await session.createTab(url: url, activate: true, from: context)
        }
    }

    /// Confirms external-link delivery at its command boundary, before later selection changes.
    /// An expected profile is checked before mutation or engine surface creation.
    public func openTabForDelivery(url: URL, expectedProfileID: ProfileID? = nil, expectedSpaceID: SpaceID? = nil) -> Task<BrowserTab?, Never> {
        pendingCommandCount += 1
        let previous = pending
        let delivery = Task<BrowserTab?, Never> { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            guard !isClosed else { return nil }
            var created: BrowserTab?
            do {
                if let spaceID = expectedSpaceID {
                    let catalog = await store.catalogSnapshot()
                    guard catalog.spaces.contains(where: { $0.id == spaceID && $0.profileID == expectedProfileID }) else { return nil }
                    try await withAdoptedContext { context in
                        let state = try await store.activateSpace(spaceID, from: context)
                        install(state)
                    }
                }
                try await createTab(url: url, activate: true, expectedProfileID: expectedProfileID, onCreate: { created = $0 })
            } catch {
                if !isClosed { onError?(error) }
            }
            // A committed logical tab survives window closure. Presentation failure must not
            // turn that successful mutation into a second tab on fallback or retry.
            return created
        }
        pending = Task { _ = await delivery.value }
        return delivery
    }

    /// Accepts an already live engine surface without replaying its request or changing selection.
    /// Source ownership is captured synchronously; later commands cannot retarget it to another
    /// Space or profile. The returned task joins the command chain before this method returns.
    public func adoptSurface(
        _ surface: Surface, from sourceSurface: Surface, profileID: ProfileID, url: URL
    ) -> Task<TabOccurrenceID?, Never> {
        let reservation = BrowserSurfaceProvenance.reserve(surface, for: self)
        let sourceID = occurrenceID(for: sourceSurface)
        let sourceAuthority = sourceID.flatMap { authorities[$0] }
        pendingCommandCount += 1
        let previous = pending
        let adoption = Task<TabOccurrenceID?, Never> { [self] in
            defer {
                if reservation != nil, occurrencesBySurface[ObjectIdentifier(surface)] == nil { disposeSurface(surface) }
                pendingCommandCount -= 1
            }
            await previous?.value
            // Protected offers are still command boundaries. Their nil result must follow earlier
            // work, while disposal remains exclusively the responsibility of the existing owner.
            guard !isClosed, let reservation, let sourceID, let sourceAuthority,
                  BrowserSurfaceProvenance.isReserved(reservation, surface: surface, for: self),
                  sourceAuthority.profileID == profileID,
                  surfaces[sourceID] === sourceSurface, authorities[sourceID] == sourceAuthority,
                  occurrencesBySurface[ObjectIdentifier(surface)] == nil else { return nil }
            do {
                guard let context = try await validatedContext(),
                      sourceAuthority.windowID == context.windowID,
                      sourceAuthority.spaceID == context.spaceID,
                      sourceAuthority.profileID == context.profileID,
                      BrowserSurfaceProvenance.isReserved(reservation, surface: surface, for: self) else { return nil }
                // The target may have redirected since creation; record where it is now.
                let recordedURL = surface.currentURL ?? url
                guard let (occurrenceID, state) = try await store.openProvidedSurfaceTab(
                    url: recordedURL, from: context, source: sourceAuthority, lifetime: surfaceCommandLifetime,
                    providedLifetime: reservation.lifetime
                ), !isClosed, BrowserSurfaceProvenance.bind(reservation, surface: surface, to: self) else { return nil }
                // Record ownership before reconciliation invokes factories or disposal callbacks.
                // A reentrant close then retires this exact provided instance with the whole batch.
                record(surface, as: occurrenceID, authority: state.occurrenceAuthorities[occurrenceID])
                install(state)
                reconcileDestination(of: surface, recorded: recordedURL)
                return isClosed ? nil : self.occurrenceID(for: surface)
            } catch {
                // Late engine callbacks can outlive their source authority. Rejection is terminal
                // for this offered surface and must not interrupt subsequent user commands.
                return nil
            }
        }
        pending = Task { _ = await adoption.value }
        return adoption
    }

    public func selectOccurrence(_ occurrenceID: TabOccurrenceID) {
        enqueue { session in
            guard let context = try await session.validatedContext() else { return }
            let state = try await session.store.selectOccurrenceUpdating(occurrenceID, from: context,
                state: session.selectionState, index: session.organizationRuntime.metadataIndex)
            guard !session.isClosed else { return }
            session.install(state)
        }
    }

    /// Foregrounds a response only if no intervening selection or context change occurred.
    /// An A-to-B-to-A round trip still differs by revision and is silently rejected.
    public func selectOccurrence(
        _ occurrenceID: TabOccurrenceID, ifContextMatches expectedContext: BrowserContext
    ) -> Task<Bool, Never> {
        selectOccurrence(occurrenceID, ifContextMatches: expectedContext, while: BrowserSelectionIntent())
    }

    /// The same intent is checked under lock at the model commit, including after the actor hop.
    /// Revocation after a successful commit does not suppress its authoritative state publication.
    public func selectOccurrence(
        _ occurrenceID: TabOccurrenceID, ifContextMatches expectedContext: BrowserContext,
        `while` intent: BrowserSelectionIntent
    ) -> Task<Bool, Never> {
        guard !isClosed else { return Task { false } }
        pendingCommandCount += 1
        let previous = pending
        let selection = Task<Bool, Never> { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            guard !isClosed, !intent.isRevoked, activeContext == expectedContext,
                  let surface = surfaces[occurrenceID], let authority = authorities[occurrenceID],
                  let ownership = BrowserSurfaceProvenance.ownedRecord(for: surface, owner: self),
                  authority.spaceID == expectedContext.spaceID,
                  authority.profileID == expectedContext.profileID else { return false }
            do {
                try validateContext(expectedContext)
                guard let state = try await store.selectProvidedSurfaceTab(
                    authority, ifContextMatches: expectedContext, lifetime: surfaceCommandLifetime,
                    targetLifetime: ownership.lifetime, intent: intent,
                    state: selectionState, index: organizationRuntime.metadataIndex
                ), !isClosed else { return false }
                install(state)
                return !isClosed && snapshot?.selectedOccurrenceID == occurrenceID
            } catch { return false }
        }
        pending = Task { _ = await selection.value }
        return selection
    }

    /// Resolves selection in command order, so New Tab then Close closes the new occurrence.
    public func closeSelectedTab() {
        enqueue { session in
            guard let context = try await session.validatedContext(),
                  let occurrenceID = context.selectedOccurrenceID else { return }
            try await session.closeTab(occurrenceID, from: context)
        }
    }

    /// Closes an exact row in the current Space without first changing selection.
    public func closeOccurrence(_ occurrenceID: TabOccurrenceID) {
        enqueue { session in
            try await session.withAdoptedContext { context in try await session.closeTab(occurrenceID, from: context) }
        }
    }

    /// Closes this exact live engine surface without activating its Space or changing profiles.
    /// Ownership is captured before queue insertion; rejection still follows all earlier commands.
    public func closeOwnedSurface(_ surface: Surface) -> Task<Bool, Never> {
        let occurrenceID = occurrenceID(for: surface)
        let authority = occurrenceID.flatMap { authorities[$0] }
        let ownership = BrowserSurfaceProvenance.ownedRecord(for: surface, owner: self)
        pendingCommandCount += 1
        let previous = pending
        let closure = Task<Bool, Never> { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            guard !isClosed, let occurrenceID, let authority, let ownership,
                  surfaces[occurrenceID] === surface, authorities[occurrenceID] == authority,
                  BrowserSurfaceProvenance.ownedRecord(for: surface, owner: self) === ownership else { return false }
            do {
                guard let context = try await validatedContext(),
                      BrowserSurfaceProvenance.ownedRecord(for: surface, owner: self) === ownership,
                      let state = try await store.closeOwnedSurfaceTab(authority, validating: context,
                          lifetime: surfaceCommandLifetime, targetLifetime: ownership.lifetime),
                      !isClosed else { return false }
                install(state)
                return !isClosed && self.occurrenceID(for: surface) == nil
            } catch { return false }
        }
        pending = Task { _ = await closure.value }
        return closure
    }

    /// Creates a fresh document at the current URL; it does not clone POST, DOM, or form state.
    public func duplicateSelectedTab() {
        enqueue { session in
            guard let context = try await session.validatedContext(),
                  let occurrenceID = context.selectedOccurrenceID,
                  let url = session.surfaces[occurrenceID]?.currentURL
                    ?? session.snapshot?.tabs.first(where: { $0.occurrenceID == occurrenceID })?.url else { return }
            try await session.createTab(url: url, activate: true, from: context)
        }
    }

    /// Compatibility entry point; the archive is the only source of closed tabs.
    public func reopenClosedTab() { restoreMostRecentArchivedTab() }

    /// Navigation shares command order with selection and Space activation.
    public func performOnSelectedSurface(
        createIfMissing: Bool = false,
        _ action: @escaping (Surface) -> Void
    ) {
        enqueue { session in
            if session.selectedSurface == nil, createIfMissing {
                try await session.createTab(url: URL(string: "about:blank")!, activate: true)
            }
            guard try await session.validatedContext() != nil,
                  let surface = session.selectedSurface else { return }
            action(surface)
        }
    }

    /// Orders native window UI with model commands, including when the active Space has no surface.
    public func performWindowAction(_ action: @escaping @MainActor () -> Void) {
        enqueue { session in
            guard try await session.validatedContext() != nil else { return }
            action()
        }
    }

    /// Persists metadata for this exact live occurrence, including an inactive Space or profile.
    /// Current shell authority is checked independently, so out-of-band switching is still rejected.
    public func updateDestination(for surface: Surface, to url: URL) {
        enqueue { session in
            guard let occurrenceID = session.occurrenceID(for: surface),
                  let authority = session.authorities[occurrenceID] else {
                throw BrowserWindowSessionError.surfaceNotOwned
            }
            try await session.withAdoptedContext { context in
                let changed = try await session.store.updateDestination(to: url, from: authority, validating: context)
                guard changed else { return }
                try await session.refreshOrganizationState(allowMetadata: true)
            }
        }
    }

    /// Revokes UI authority synchronously; model cleanup follows already issued actor mutations.
    public func close() { retire(removeModelWindow: true) }

    /// Terminal retirement preserving all Spaces in the model for restoration.
    /// Await pending commands before taking the final document. A later close() is a no-op.
    public func retireForApplicationTermination() { retire(removeModelWindow: false) }

    func retire(removeModelWindow: Bool) {
        guard !isClosed else { return }
        for authority in spaceSettingsActions.values { authority.revoke() }
        spaceSettingsActions.removeAll()
        surfaceCommandLifetime.revoke()
        for admission in bookmarkAdmissions.values { admission.revoke() }
        bookmarkAdmissions.removeAll()
        isClosed = true
        let transferCancellations = Array(bookmarkTransferCancellations.values)
        bookmarkTransferCancellations.removeAll()
        for cancel in transferCancellations { cancel() }
        let retired = ownedSurfaces
        surfaces.removeAll()
        surfaceOrder.removeAll()
        occurrencesBySurface.removeAll()
        authorities.removeAll()
        modelOccurrenceAuthorities.removeAll()
        occurrenceTabIDs.removeAll()
        activeContext = nil
        snapshot = nil
        catalog = nil
        organizationRuntime.retire()
        onChange = nil
        onMetadataChange = nil
        selectionChangeTabIDs = nil
        onError = nil
        onSurfaceMembershipChange = nil
        // Moves in flight from this window lose their return path and go to the rescue holder.
        transits.removeAll()
        for surface in retired { BrowserSurfaceProvenance.revoke(surface, ownedBy: self) }
        for surface in retired { disposeSurface(surface) }
        let previous = pending
        pendingCommandCount += 1
        pending = Task { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            if removeModelWindow, let windowID { try? await store.closeWindow(windowID) }
        }
    }

    /// Settles the ordinary FIFO, including commands appended by reentrant callbacks.
    /// An accepted standalone file export does not delay unrelated interface commands.
    public func waitForQueuedCommands() async {
        while pendingCommandCount > 0 {
            await pending?.value
        }
    }

    /// Lifecycle draining also retains accepted file writes through final save and retirement.
    public func waitForPendingCommands() async {
        while pendingCommandCount > 0 || !acceptedBookmarkExports.isEmpty {
            await waitForQueuedCommands()
            for task in Array(acceptedBookmarkExports.values) { _ = try? await task.value }
        }
    }

    /// Inserts a read boundary synchronously: earlier commands finish before capture, and later
    /// commands wait for its result. Closure or rejected authority always resolves to nil.
    public func captureContextInCommandOrder() -> Task<BrowserContext?, Never> {
        guard !isClosed else { return Task { nil } }
        pendingCommandCount += 1
        let previous = pending
        let boundary = Task<BrowserContext?, Never> { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            guard !isClosed else { return nil }
            do { return try await validatedContext() }
            catch {
                guard !isClosed else { return nil }
                onError?(error)
                return nil
            }
        }
        pending = Task { _ = await boundary.value }
        return boundary
    }

    func adoptWindow(_ windowID: WindowID) async throws {
        guard !isClosed else { return }
        BrowserPerformance.mark(.sessionAdoptBegin)
        let state = try await store.materializeVisibleSplitAndCaptureState(in: windowID)
        BrowserPerformance.mark(.sessionCaptured)
        guard !isClosed else { return }
        guard await store.isCurrent(state.context) else { throw BrowserStoreError.staleContext }
        BrowserPerformance.mark(.sessionValidated)
        install(state)
    }

    /// No actor hop or external callback occurs between acquiring a surface and recording ownership.
    /// A reentrant close retires both previously owned surfaces and the newly returned one exactly once.
    func installMetadata(_ delta: BrowserOrganizationMetadata) {
        guard !isClosed, let current = organizationRuntime.snapshot else { return }
        organizationRuntime.snapshot = current.applying(delta, index: organizationRuntime.metadataIndex)
        snapshot = snapshot?.applying(delta, indices: organizationRuntime.occurrenceIndices)
        if !delta.tabs.isEmpty {
            if let onMetadataChange { onMetadataChange(Set(delta.tabs.keys)) }
            else { onChange?() }
        }
    }

    func install(_ state: BrowserWindowState) {
        let perfStart = BrowserPerformance.begin()
        defer { BrowserPerformance.end(.sessionInstall, since: perfStart) }
        guard !isClosed else { return }
        // A placeholder follows its model occurrence, including to another Space of its profile;
        // one that left the model or its profile loses its return path (a failed move then goes
        // to the rescue holder).
        for (occurrenceID, transit) in transits {
            guard let authority = state.occurrenceAuthorities[occurrenceID],
                  transit.authority.canRetainSurface(as: authority) else {
                transits.removeValue(forKey: occurrenceID)
                continue
            }
            transits[occurrenceID]?.authority = authority
        }
        // An occurrence moved to another Space of the same profile keeps its live surface.
        let removedIDs = Set(surfaceOrder.filter { id in
            guard let current = authorities[id], let next = state.occurrenceAuthorities[id] else { return true }
            return !current.canRetainSurface(as: next)
        })
        var retired: [Surface] = []
        for occurrenceID in surfaceOrder where removedIDs.contains(occurrenceID) {
            if let surface = surfaces.removeValue(forKey: occurrenceID) {
                occurrencesBySurface.removeValue(forKey: ObjectIdentifier(surface))
                retired.append(surface)
            }
            authorities.removeValue(forKey: occurrenceID)
        }
        surfaceOrder.removeAll { removedIDs.contains($0) }
        for id in surfaceOrder { authorities[id] = state.occurrenceAuthorities[id] }
        // Revoke the whole batch before any disposal callback. Reentrant close() owns only the
        // remaining surfaces; every detached surface must still be disposed even after that close.
        for surface in retired { BrowserSurfaceProvenance.revoke(surface, ownedBy: self) }
        for surface in retired { disposeSurface(surface) }
        guard !isClosed else { return }
        var created: [(TabOccurrenceID, Surface, URL)] = []
        let visible = visibleOccurrenceIDs(in: state)
        for tab in state.snapshot.tabs
        where (surfaceLoadingPolicy == .eager || visible.contains(tab.occurrenceID) || requestedSurfaceIDs.contains(tab.occurrenceID))
            && surfaces[tab.occurrenceID] == nil && transits[tab.occurrenceID] == nil {
            guard let surface = makeSurface(state.context.profileID, tab.url) else {
                if !isClosed { onError?(BrowserWindowSessionError.surfaceUnavailable) }
                break
            }
            guard BrowserSurfaceProvenance.registerFactorySurface(surface, for: self) else {
                if !isClosed { onError?(BrowserWindowSessionError.surfaceNotOwned) }
                return
            }
            guard !isClosed else { disposeSurface(surface); return }
            record(surface, as: tab.occurrenceID, authority: state.occurrenceAuthorities[tab.occurrenceID])
            created.append((tab.occurrenceID, surface, tab.url))
        }
        BrowserPerformance.mark(.sessionSurfacesReady)
        requestedSurfaceIDs.subtract(created.map { $0.0 })
        activeContext = state.context
        modelOccurrenceAuthorities = state.occurrenceAuthorities
        occurrenceTabIDs = state.occurrenceTabIDs
        snapshot = state.snapshot
        catalog = state.catalog
        organizationRuntime.catalogRevision = state.catalogRevision
        organizationRuntime.activityRevision = state.activityRevision
        organizationRuntime.snapshot = state.organization
        if state.selectionTabIDs == nil {
            organizationRuntime.metadataIndex = BrowserOrganizationMetadataIndex(state.organization)
            organizationRuntime.occurrenceIndices = Dictionary(uniqueKeysWithValues: state.snapshot.tabs.enumerated().map { ($0.element.occurrenceID, $0.offset) })
        }
        // Loads start only after ownership, membership and the new state are visible, so events
        // delivered synchronously by the engine see a consistent owner.
        if let startSurface {
            for (occurrenceID, surface, url) in created where !isClosed && surfaces[occurrenceID] === surface {
                startSurface(surface, url)
            }
        }
        guard !isClosed else { return }
        BrowserPerformance.mark(.sessionNavigated)
        let previousSelectionChange = selectionChangeTabIDs
        // Surface admission retains the complete presentation path, including live Favorite
        // activity and icon adoption. Only already-owned documents use the selection hint.
        selectionChangeTabIDs = created.isEmpty ? state.selectionTabIDs : nil
        onChange?()
        selectionChangeTabIDs = isClosed ? nil : previousSelectionChange
        BrowserPerformance.mark(.sessionRendered)
    }

    /// Records ownership maps and reports membership. No actor hop or engine callback may run
    /// between acquiring a surface and this call.
    func record(_ surface: Surface, as occurrenceID: TabOccurrenceID, authority: BrowserOccurrenceAuthority?,
                at orderIndex: Int? = nil, notifying: Bool = true) {
        surfaces[occurrenceID] = surface
        surfaceOrder.insert(occurrenceID, at: min(orderIndex ?? surfaceOrder.count, surfaceOrder.count))
        occurrencesBySurface[ObjectIdentifier(surface)] = occurrenceID
        authorities[occurrenceID] = authority
        if notifying, let windowID {
            onSurfaceMembershipChange?(surface, BrowserSurfaceMembership(windowID: windowID, occurrenceID: occurrenceID))
        }
    }

    func disposeSurface(_ surface: Surface) {
        BrowserSurfaceProvenance.dispose(surface, ownedBy: self)
    }

    private func visibleOccurrenceIDs(in state: BrowserWindowState) -> Set<TabOccurrenceID> {
        guard let selected = state.snapshot.selectedOccurrenceID else { return [] }
        guard let tab = state.snapshot.tabs.first(where: { $0.occurrenceID == selected }),
              let split = state.organization.split(containing: tab.id) else { return [selected] }
        return Set(split.tabs.compactMap(\.occurrenceID))
    }

    public var visibleOccurrenceIDs: Set<TabOccurrenceID> {
        if let split = activeSplit { return Set(split.tabs.compactMap(\.occurrenceID)) }
        return Set([snapshot?.selectedOccurrenceID].compactMap { $0 })
    }

    /// Retires a background engine while keeping its logical tab, occurrence, title and order.
    /// The owner checks document safety first. A selection or transfer queued during that check
    /// refuses retirement; there is no actor hop between this final check and disposal.
    @discardableResult
    public func suspendSurface(_ surface: Surface) -> Bool {
        guard surfaceLoadingPolicy == .visibleOnly, !isClosed, !hasPendingCommands,
              let id = occurrenceID(for: surface), !visibleOccurrenceIDs.contains(id),
              transits[id] == nil, authorities[id] == modelOccurrenceAuthorities[id] else { return false }
        switch surface.suspendInPlace() {
        case .refused: return false
        case .suspended:
            onChange?()
            return true
        case .unsupported: break
        }
        surfaces.removeValue(forKey: id)
        occurrencesBySurface.removeValue(forKey: ObjectIdentifier(surface))
        authorities.removeValue(forKey: id)
        surfaceOrder.removeAll { $0 == id }
        disposeSurface(surface)
        onChange?()
        return true
    }

    func refreshCatalog(from context: BrowserContext) async throws {
        let state = try await store.captureWindowState(from: context)
        guard !isClosed else { return }
        let hasRevokedSurface = surfaceOrder.contains { authorities[$0] != state.occurrenceAuthorities[$0] }
        guard catalog != state.catalog || snapshot != state.snapshot || hasRevokedSurface
                || organizationRuntime.snapshot != state.organization else { return }
        install(state)
    }

    func closeTab(_ occurrenceID: TabOccurrenceID, from context: BrowserContext) async throws {
        guard !isClosed else { return }
        let state = try await store.closeOccurrenceAndCaptureState(occurrenceID, from: context)
        guard !isClosed else { return }
        install(state)
    }

    func createTab(url: URL, activate: Bool, from capturedContext: BrowserContext? = nil,
                   expectedProfileID: ProfileID? = nil, onCreate: ((BrowserTab) -> Void)? = nil) async throws {
        let context: BrowserContext
        if let capturedContext {
            try validateContext(capturedContext)
            guard expectedProfileID == nil || capturedContext.profileID == expectedProfileID else { return }
            context = capturedContext
        } else {
            // Opening is not idempotent: only the refused attempt is retried, never a created tab.
            var created: (BrowserContext, BrowserTab)?
            try await withAdoptedContext { current in
                guard expectedProfileID == nil || current.profileID == expectedProfileID else { return }
                let perfStart = BrowserPerformance.begin()
                let tab = try await store.openTabAndCaptureDelivery(url: url, from: current, activate: activate)
                BrowserPerformance.end(.storeOpenAwait, since: perfStart)
                onCreate?(tab)
                created = (current, tab)
            }
            guard let (current, tab) = created else { return }
            requestedSurfaceIDs.insert(tab.occurrenceID)
            if let state = try await stateAfterMutation(current, revision: current.revision &+ (activate ? 1 : 0),
                selection: activate ? tab.occurrenceID : current.selectedOccurrenceID, adoptingOrganizationChanges: true) {
                install(state)
            }
            return
        }
        let tab = try await store.openTabAndCaptureDelivery(url: url, from: context, activate: activate)
        requestedSurfaceIDs.insert(tab.occurrenceID)
        onCreate?(tab)
        if let state = try await stateAfterMutation(context,
            revision: context.revision &+ (activate ? 1 : 0),
            selection: activate ? tab.occurrenceID : context.selectedOccurrenceID) {
            install(state)
        }
    }

    func stateAfterMutation(
        _ context: BrowserContext, revision: UInt64, selection: TabOccurrenceID?,
        adoptingOrganizationChanges: Bool = false
    ) async throws -> BrowserWindowState? {
        guard !isClosed else { return nil }
        let perfStart = BrowserPerformance.begin()
        let state = try await store.captureWindowState(in: context.windowID)
        BrowserPerformance.end(.storeCaptureAwait, since: perfStart)
        guard !isClosed else { return nil }
        guard state.context.spaceID == context.spaceID, state.context.profileID == context.profileID else {
            throw BrowserWindowSessionError.contextChangeRequiresNewSession
        }
        guard state.context.storeGeneration == context.storeGeneration,
              state.context.revision == revision, state.context.selectedOccurrenceID == selection else {
            if adoptingOrganizationChanges,
               let adopted = try await store.windowState(adoptingOrganizationChangesSince: context, revision: revision) {
                return isClosed ? nil : adopted
            }
            throw BrowserStoreError.staleContext
        }
        return state
    }

    /// For commands that do not act on the selection, which must be atomic or idempotent in the
    /// store: when another window's organization command changes this window's selection while
    /// the command is in flight (the store refuses its context as stale and vouches for that
    /// cause), the change is installed and the command runs again on the refreshed state.
    func withAdoptedContext(_ body: (BrowserContext) async throws -> Void) async throws {
        var attempt = 1
        while true {
            guard let context = try await validatedContext(adoptingOrganizationChanges: true) else { return }
            do {
                return try await body(context)
            } catch BrowserStoreError.staleContext where attempt < maximumOrganizationAdoptions {
                attempt += 1
                guard !isClosed, let state = try await store.windowState(adoptingOrganizationChangesSince: context) else {
                    throw BrowserStoreError.staleContext
                }
                guard !isClosed else { return }
                install(state)
            }
        }
    }

    /// With `adoptingOrganizationChanges`, a command that does not act on the selection first
    /// installs a selection change caused only by another window's organization command (its
    /// visible tab archived or moved away) instead of being refused as stale; the store vouches
    /// that nothing else changed. Commands on the selection (close, duplicate, navigate the
    /// selected tab, page zoom) stay strict: the tab the user meant may be gone.
    func validatedContext(adoptingOrganizationChanges: Bool = false) async throws -> BrowserContext? {
        guard !isClosed, let windowID else { return nil }
        let perfStart = BrowserPerformance.begin()
        let context = try await store.captureContext(in: windowID)
        BrowserPerformance.end(.storeContextAwait, since: perfStart)
        guard !isClosed else { return nil }
        do {
            try validateContext(context)
        } catch BrowserStoreError.staleContext where adoptingOrganizationChanges {
            guard let activeContext,
                  let state = try await store.windowState(adoptingOrganizationChangesSince: activeContext) else {
                throw BrowserStoreError.staleContext
            }
            guard !isClosed else { return nil }
            install(state)
            guard !isClosed else { return nil }
            try validateContext(state.context)
            return state.context
        }
        return context
    }

    func enqueue(_ action: @escaping @MainActor (BrowserWindowSession) async throws -> Void) {
        guard !isClosed else { return }
        let queued = BrowserPerformance.begin()
        pendingCommandCount += 1
        let previous = pending
        pending = Task { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            BrowserPerformance.end(.commandQueue, since: queued)
            guard !isClosed else { return }
            do { try await action(self) }
            catch {
                guard !isClosed else { return }
                onError?(error)
            }
        }
    }

    func validateContext(_ context: BrowserContext) throws {
        guard !isClosed, context.windowID == windowID, context.windowID == snapshot?.id,
              let activeContext else { throw BrowserStoreError.staleContext }
        guard context.profileID == activeContext.profileID, context.spaceID == activeContext.spaceID else {
            throw BrowserWindowSessionError.contextChangeRequiresNewSession
        }
        guard context == activeContext else { throw BrowserStoreError.staleContext }
    }
}
