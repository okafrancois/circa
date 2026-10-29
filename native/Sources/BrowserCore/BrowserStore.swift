import Foundation

public struct ProfileID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct SpaceID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct WindowID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct TabID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct TabOccurrenceID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum BrowserStoreError: Error, Equatable, Sendable {
    case profileMissing
    case spaceMissing
    case windowMissing
    case tabMissing
    case occurrenceOwnedByAnotherWindow
    case staleContext
    case invalidSpaceName
}

public struct BrowserProfile: Codable, Equatable, Sendable {
    public let id: ProfileID
    public let name: String
}

public struct BrowserSpace: Codable, Equatable, Sendable {
    public let id: SpaceID
    public let profileID: ProfileID
    public let name: String
    /// Session version 4 (Space themes). nil: never themed — the legacy Settings palette or the default
    /// theme applies. Travels with the Space (rename, profile reassignment).
    public internal(set) var theme: BrowserSpaceTheme? = nil
}

public struct BrowserCatalogSnapshot: Equatable, Sendable {
    public let profiles: [BrowserProfile]
    public let spaces: [BrowserSpace]

    public init(profiles: [BrowserProfile], spaces: [BrowserSpace]) {
        self.profiles = profiles
        self.spaces = spaces
    }
}

public struct BrowserTab: Codable, Equatable, Sendable {
    public let id: TabID
    public let occurrenceID: TabOccurrenceID
    public let windowID: WindowID
    public let spaceID: SpaceID
    public let url: URL
}

public struct BrowserContext: Equatable, Sendable {
    public let storeGeneration: UUID
    public let windowID: WindowID
    public let spaceID: SpaceID
    public let profileID: ProfileID
    public let selectedOccurrenceID: TabOccurrenceID?
    public let revision: UInt64
}

public struct BrowserWindowSnapshot: Equatable, Sendable {
    public let id: WindowID
    public let activeSpaceID: SpaceID
    public let selectedOccurrenceID: TabOccurrenceID?
    public let tabs: [BrowserTab]
    public let revision: UInt64
    public var isStandalone: Bool = false
}

/// Identifies one existing occurrence independently of active Space and selection.
/// This lease alone cannot authorize navigation, creation, selection, or destructive actions.
/// Exact closure additionally requires an independently validated current window context.
public struct BrowserOccurrenceAuthority: Equatable, Sendable {
    public let storeGeneration: UUID
    public let windowID: WindowID
    public let spaceID: SpaceID
    public let profileID: ProfileID
    public let occurrenceID: TabOccurrenceID
}

/// An atomic view of a window and the catalog, including all of its active and inactive leases.
public struct BrowserWindowState: Sendable {
    public let context: BrowserContext
    public let snapshot: BrowserWindowSnapshot
    public let catalog: BrowserCatalogSnapshot
    /// The complete occurrence inventory of this window. Its absence revokes a previously owned lease.
    public let occurrenceAuthorities: [TabOccurrenceID: BrowserOccurrenceAuthority]
    /// Logical identities for exactly the same active and inactive occurrence inventory.
    public let occurrenceTabIDs: [TabOccurrenceID: TabID]
    /// Favorites, Pinned and Today as this window sees its active Space, captured in the same turn.
    public let organization: BrowserOrganizationSnapshot
}

struct WindowRecord {
    let id: WindowID
    var activeSpaceID: SpaceID
    var selectedOccurrenceBySpace: [SpaceID: TabOccurrenceID] = [:]
    var occurrenceIDsBySpace: [SpaceID: [TabOccurrenceID]] = [:]
    /// Pages loaded only to fill an archive-selection gap may be retired by its undo. Explicit
    /// selection claims them normally; this transient provenance is never persisted.
    var organizationFallbackOccurrences: Set<TabOccurrenceID> = []
    var placement: BrowserWindowPlacement?
    var standaloneProfileID: ProfileID?
    var revision: UInt64 = 0
    /// Consecutive revisions produced only by reconciling this window's occurrences after an
    /// organization change made elsewhere; any other revision change starts outside the range.
    var reconciledRevisions: ClosedRange<UInt64>?

    mutating func recordReconciliation(from start: UInt64) {
        guard start < revision else { reconciledRevisions = nil; return }
        if let span = reconciledRevisions, span.upperBound == start {
            reconciledRevisions = span.lowerBound...revision
        } else {
            reconciledRevisions = start...revision
        }
    }
}

/// Owns browser state without depending on AppKit or a web engine.
public actor BrowserStore {
    let storeGeneration = UUID()
    nonisolated let spaceSettingsOwnership = BrowserSpaceSettingsOwnership()
    var profiles: [ProfileID: BrowserProfile] = [:] {
        willSet { spaceSettingsOwnership.synchronize(spaces: spaces, profiles: Set(newValue.keys), excluding: deletingProfiles, windows: windows) }
    }
    var deletingProfiles: Set<ProfileID> = [] {
        willSet { spaceSettingsOwnership.synchronize(spaces: spaces, profiles: Set(profiles.keys), excluding: newValue, windows: windows) }
    }
    var spaces: [SpaceID: BrowserSpace] = [:] {
        willSet { spaceSettingsOwnership.synchronize(spaces: newValue, profiles: Set(profiles.keys), excluding: deletingProfiles, windows: windows) }
    }
    var profileOrder: [ProfileID] = []
    var spaceOrder: [SpaceID] = []
    var windows: [WindowID: WindowRecord] = [:] {
        willSet { spaceSettingsOwnership.synchronize(spaces: spaces, profiles: Set(profiles.keys), excluding: deletingProfiles, windows: newValue) }
    }
    var tabs: [TabOccurrenceID: BrowserTab] = [:]
    // Sidebar organization shared by windows; commands live in Organization/BrowserStore+Organization.swift.
    var organization = BrowserOrganizationState() {
        didSet {
            // Replacing shared organization (for example after import or remote reconciliation)
            // cannot erase window-local records which are deliberately absent from that document.
            for id in oldValue.standalone.keys where organization.standalone[id] == nil {
                guard let home = oldValue.standaloneHomes[id], let profile = windows[id]?.standaloneProfileID else { continue }
                let local = oldValue.standaloneDocument(id, profileID: profile)
                try? organization.restoreStandalone(local, windowID: id, home: home)
            }
        }
    }
    var organizationJournals: [WindowID: BrowserOrganizationJournal] = [:]
    var organizationObservers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    var organizationRevision: UInt64 = 0
    /// Spaces whose imported Orbit appearance was already considered (one-time theme migration).
    var themeImports: Set<SpaceID> = []
    /// Injected so inactivity thresholds are deterministic in tests.
    let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public init(restoring document: BrowserSessionDocument, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.clock = clock
        try document.validate()
        profiles = Dictionary(uniqueKeysWithValues: document.profiles.map { ($0.id, $0) })
        spaces = Dictionary(uniqueKeysWithValues: document.spaces.map { ($0.id, $0) })
        profileOrder = document.profiles.map(\.id)
        spaceOrder = document.spaces.map(\.id)
        tabs = Dictionary(uniqueKeysWithValues: document.tabs.map { ($0.occurrenceID, $0) })
        for saved in document.windows {
            var window = WindowRecord(id: saved.id, activeSpaceID: saved.activeSpaceID)
            window.placement = saved.placement
            window.standaloneProfileID = saved.standalone?.profileID
            for group in saved.spaces {
                window.occurrenceIDsBySpace[group.spaceID] = group.occurrenceIDs
                window.selectedOccurrenceBySpace[group.spaceID] = group.selectedOccurrenceID
            }
            windows[saved.id] = window
        }
        organization = try BrowserOrganizationState(document: document.organization)
        for saved in document.windows {
            if let local = saved.standalone { try organization.restoreStandalone(local, windowID: saved.id, home: saved.activeSpaceID) }
        }
        themeImports = Set(document.themeImports)
        spaceSettingsOwnership.synchronize(spaces: spaces, profiles: Set(profiles.keys), excluding: deletingProfiles, windows: windows)
    }

    /// A synchronous snapshot capability captures ownership before an editor or
    /// queued UI action can wait. Epochs revoke A→B→A and removal/restoration.
    public nonisolated func captureSpaceSettingsAuthority(for id: SpaceID, profileID: ProfileID,
                                                          sourceWindow: WindowID? = nil, sourceProfile: ProfileID? = nil) -> BrowserSpaceSettingsAuthority? {
        spaceSettingsOwnership.capture(spaceID: id, profileID: profileID, sourceWindow: sourceWindow, sourceProfile: sourceProfile)
    }

    /// Layout changes do not revoke document or command contexts.
    public func updateWindowPlacements(_ placements: [WindowID: BrowserWindowPlacement]) {
        for (id, placement) in placements where placement.isUsable && windows[id] != nil {
            windows[id]?.placement = placement
        }
    }

    public func sessionDocument() -> BrowserSessionDocument {
        let savedWindows = windows.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }.map { window in
            let spaceIDs = Set(window.occurrenceIDsBySpace.keys)
                .union(window.selectedOccurrenceBySpace.keys).union([window.activeSpaceID])
            let groups = spaceIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }.map { spaceID in
                BrowserSessionDocument.SpaceTabs(
                    spaceID: spaceID,
                    occurrenceIDs: window.occurrenceIDsBySpace[spaceID, default: []],
                    selectedOccurrenceID: window.selectedOccurrenceBySpace[spaceID]
                )
            }
            return BrowserSessionDocument.Window(id: window.id, activeSpaceID: window.activeSpaceID, spaces: groups, placement: window.placement,
                standalone: window.standaloneProfileID.map { profile in
                    organization.standaloneDocument(window.id, profileID: profile)
                })
        }
        return BrowserSessionDocument(
            profiles: profileOrder.compactMap { profiles[$0] },
            spaces: spaceOrder.compactMap { spaces[$0] },
            windows: savedWindows,
            tabs: tabs.values.sorted { $0.occurrenceID.rawValue.uuidString < $1.occurrenceID.rawValue.uuidString },
            organization: organization.document(profileOrder: profileOrder, spaceOrder: spaceOrder),
            themeImports: themeImports.filter { spaces[$0] != nil }.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        )
    }

    @discardableResult
    public func createProfile(name: String) -> ProfileID {
        let id = ProfileID()
        profiles[id] = BrowserProfile(id: id, name: name)
        profileOrder.append(id)
        return id
    }

    @discardableResult
    public func createSpace(name: String, profileID: ProfileID) throws -> SpaceID {
        guard profiles[profileID] != nil else { throw BrowserStoreError.profileMissing }
        try requireAvailableProfile(profileID)
        let name = try Self.validatedSpaceName(name)
        let id = SpaceID()
        spaces[id] = BrowserSpace(id: id, profileID: profileID, name: name)
        spaceOrder.append(id)
        return id
    }

    public func catalogSnapshot() -> BrowserCatalogSnapshot {
        BrowserCatalogSnapshot(profiles: profileOrder.filter { !deletingProfiles.contains($0) }.compactMap { profiles[$0] },
                               spaces: spaceOrder.compactMap { spaces[$0] }.filter { !deletingProfiles.contains($0.profileID) })
    }

    public func renameSpace(_ spaceID: SpaceID, name: String) throws {
        guard let space = spaces[spaceID] else { throw BrowserStoreError.spaceMissing }
        let name = try Self.validatedSpaceName(name)
        spaces[spaceID] = BrowserSpace(id: space.id, profileID: space.profileID, name: name, theme: space.theme)
    }

    /// Moves within the global catalog, preserving profile identity. A nil destination appends.
    public func moveSpace(_ spaceID: SpaceID, before destination: SpaceID?) throws {
        guard spaces[spaceID] != nil else { throw BrowserStoreError.spaceMissing }
        if let destination, spaces[destination] == nil { throw BrowserStoreError.spaceMissing }
        guard destination != spaceID else { return }
        spaceOrder.removeAll { $0 == spaceID }
        if let destination, let index = spaceOrder.firstIndex(of: destination) {
            spaceOrder.insert(spaceID, at: index)
        } else {
            spaceOrder.append(spaceID)
        }
    }

    public func renameSpace(_ spaceID: SpaceID, name: String, from context: BrowserContext) throws {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        try renameSpace(spaceID, name: name)
    }

    public func moveSpace(_ spaceID: SpaceID, before destination: SpaceID?, from context: BrowserContext) throws {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        try moveSpace(spaceID, before: destination)
    }

    /// Creates and activates atomically, so a stale window cannot leave an unselected catalog entry.
    public func createSpace(name: String, profileID: ProfileID, from context: BrowserContext) throws -> BrowserWindowState {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        let spaceID = try createSpace(name: name, profileID: profileID)
        return try activateSpace(spaceID, from: context)
    }

    /// Validates both names and the window before inserting either identity.
    public func createSpace(name: String, newProfileName: String, from context: BrowserContext) throws -> BrowserWindowState {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        let name = try Self.validatedSpaceName(name)
        let profileName = try Self.validatedSpaceName(newProfileName)
        let profile = try createSettingsProfile(name: profileName)
        return try createSpace(name: name, profileID: profile, from: context)
    }

    static func validatedSpaceName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw BrowserStoreError.invalidSpaceName
        }
        return trimmed
    }

    @discardableResult
    public func createWindow(activeSpaceID: SpaceID) throws -> WindowID {
        guard let space = spaces[activeSpaceID] else { throw BrowserStoreError.spaceMissing }
        try requireAvailableProfile(space.profileID)
        let id = WindowID()
        windows[id] = WindowRecord(id: id, activeSpaceID: activeSpaceID)
        return id
    }

    /// Removes the window and its occurrences. Its logical tabs stay in the shared sidebar.
    public func closeWindow(_ windowID: WindowID) throws {
        markViewed(windows[windowID])
        guard let window = windows.removeValue(forKey: windowID) else {
            throw BrowserStoreError.windowMissing
        }
        for occurrenceIDs in window.occurrenceIDsBySpace.values {
            for occurrenceID in occurrenceIDs { tabs.removeValue(forKey: occurrenceID) }
        }
        if window.standaloneProfileID != nil {
            for node in organization.standalone[windowID] ?? [] {
                let ids = organization.tabIDs(in: node)
                for id in ids { organization.detach(.tab(id)); organization.tabs[id] = nil }
                organization.detach(node)
                if let group = node.splitID { organization.splits[group] = nil }
            }
            organization.standalone[windowID] = nil
            organization.standaloneHomes[windowID] = nil
        }
        organizationDidCloseWindow(windowID)
    }

    public func activateSpace(_ spaceID: SpaceID, in windowID: WindowID) throws {
        guard let space = spaces[spaceID] else { throw BrowserStoreError.spaceMissing }
        try requireAvailableProfile(space.profileID)
        guard var window = windows[windowID] else { throw BrowserStoreError.windowMissing }
        guard window.standaloneProfileID == nil else { throw BrowserStoreError.staleContext }
        guard window.activeSpaceID != spaceID else { ensureVisibleSplitOccurrences(in: windowID); return }
        markViewed(window)
        window.activeSpaceID = spaceID
        window.revision &+= 1
        windows[windowID] = window
        markViewed(window)
        ensureVisibleSplitOccurrences(in: windowID)
    }

    /// Validates the old authority and returns the new authority and view in the same actor turn.
    public func activateSpace(_ spaceID: SpaceID, from context: BrowserContext) throws -> BrowserWindowState {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        try activateSpace(spaceID, in: context.windowID)
        return try captureWindowState(in: context.windowID)
    }

    public func activateAdjacentSpace(offset: Int, from context: BrowserContext) throws -> BrowserWindowState {
        guard isCurrent(context), let index = spaceOrder.firstIndex(of: context.spaceID) else {
            throw BrowserStoreError.staleContext
        }
        let (proposed, overflow) = index.addingReportingOverflow(offset)
        let destination = overflow ? (offset > 0 ? spaceOrder.count - 1 : 0)
            : min(max(proposed, 0), spaceOrder.count - 1)
        return try activateSpace(spaceOrder[destination], from: context)
    }

    public func captureWindowState(in windowID: WindowID) throws -> BrowserWindowState {
        let context = try captureContext(in: windowID)
        let snapshot = try snapshot(of: windowID)
        guard let window = windows[windowID] else { throw BrowserStoreError.windowMissing }
        var authorities: [TabOccurrenceID: BrowserOccurrenceAuthority] = [:]
        var tabIDs: [TabOccurrenceID: TabID] = [:]
        for (spaceID, occurrenceIDs) in window.occurrenceIDsBySpace {
            guard let space = spaces[spaceID] else { throw BrowserStoreError.spaceMissing }
            for occurrenceID in occurrenceIDs {
                guard let tab = tabs[occurrenceID] else { throw BrowserStoreError.tabMissing }
                guard tab.windowID == windowID, tab.spaceID == spaceID else {
                    throw BrowserStoreError.occurrenceOwnedByAnotherWindow
                }
                authorities[occurrenceID] = BrowserOccurrenceAuthority(storeGeneration: storeGeneration,
                    windowID: windowID, spaceID: spaceID, profileID: window.standaloneProfileID ?? space.profileID, occurrenceID: occurrenceID)
                tabIDs[occurrenceID] = tab.id
            }
        }
        return BrowserWindowState(context: context, snapshot: snapshot, catalog: catalogSnapshot(),
                                  occurrenceAuthorities: authorities,
                                  occurrenceTabIDs: tabIDs,
                                  organization: try organizationSnapshot(for: windowID))
    }

    public func captureWindowState(from context: BrowserContext) throws -> BrowserWindowState {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        return try captureWindowState(in: context.windowID)
    }

    public func captureOccurrenceAuthority(
        for occurrenceID: TabOccurrenceID, from context: BrowserContext
    ) throws -> BrowserOccurrenceAuthority {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        guard let tab = tabs[occurrenceID] else { throw BrowserStoreError.tabMissing }
        guard tab.windowID == context.windowID, tab.spaceID == context.spaceID else {
            throw BrowserStoreError.occurrenceOwnedByAnotherWindow
        }
        return BrowserOccurrenceAuthority(storeGeneration: storeGeneration, windowID: tab.windowID,
            spaceID: tab.spaceID, profileID: context.profileID, occurrenceID: occurrenceID)
    }

    public func captureContext(in windowID: WindowID) throws -> BrowserContext {
        guard let window = windows[windowID] else { throw BrowserStoreError.windowMissing }
        let spaceID = window.activeSpaceID
        guard let space = spaces[spaceID] else { throw BrowserStoreError.spaceMissing }
        let profileID = window.standaloneProfileID ?? space.profileID
        try requireAvailableProfile(profileID)
        return BrowserContext(
            storeGeneration: storeGeneration,
            windowID: windowID,
            spaceID: spaceID,
            profileID: profileID,
            selectedOccurrenceID: window.selectedOccurrenceBySpace[spaceID],
            revision: window.revision
        )
    }

    public func isCurrent(_ context: BrowserContext) -> Bool {
        guard context.storeGeneration == storeGeneration,
              let window = windows[context.windowID],
              let space = spaces[window.activeSpaceID], !deletingProfiles.contains(space.profileID) else { return false }
        return window.activeSpaceID == context.spaceID
            && (window.standaloneProfileID ?? space.profileID) == context.profileID
            && window.selectedOccurrenceBySpace[context.spaceID] == context.selectedOccurrenceID
            && window.revision == context.revision
    }

    /// Creates a tab in the captured window and Space. Background creation leaves selection unchanged.
    @discardableResult
    public func openTab(url: URL, from context: BrowserContext, activate: Bool) throws -> TabOccurrenceID {
        guard isCurrent(context), var window = windows[context.windowID] else {
            throw BrowserStoreError.staleContext
        }
        try BrowserSessionDocument.validateDestination(url)
        let occurrenceID = TabOccurrenceID()
        let tab = BrowserTab(id: TabID(), occurrenceID: occurrenceID, windowID: context.windowID, spaceID: context.spaceID, url: url)
        if activate { markViewed(window) }
        tabs[occurrenceID] = tab
        window.occurrenceIDsBySpace[context.spaceID, default: []].append(occurrenceID)
        if activate {
            window.selectedOccurrenceBySpace[context.spaceID] = occurrenceID
            window.revision &+= 1
        }
        windows[context.windowID] = window
        organizationDidOpen(tab)
        return occurrenceID
    }

    /// Captures the successful mutation before another actor turn can close its window.
    public func openTabAndCaptureDelivery(url: URL, from context: BrowserContext, activate: Bool) throws -> BrowserTab {
        let occurrenceID = try openTab(url: url, from: context, activate: activate)
        guard let tab = tabs[occurrenceID] else { throw BrowserStoreError.tabMissing }
        return tab
    }

    public func selectOccurrence(_ occurrenceID: TabOccurrenceID, in windowID: WindowID) throws {
        guard var window = windows[windowID] else { throw BrowserStoreError.windowMissing }
        guard let tab = tabs[occurrenceID] else { throw BrowserStoreError.tabMissing }
        guard tab.windowID == windowID, tab.spaceID == window.activeSpaceID else {
            throw BrowserStoreError.occurrenceOwnedByAnotherWindow
        }
        let visibleTabs: Set<TabID>
        if case let .split(id)? = organization.container(of: .tab(tab.id)), let group = organization.splits[id] {
            visibleTabs = Set(group.tabIDs)
        } else {
            visibleTabs = [tab.id]
        }
        let claimed = window.organizationFallbackOccurrences.filter { id in
            tabs[id].map { visibleTabs.contains($0.id) } == true
        }
        let claimedFallback = !claimed.isEmpty
        window.organizationFallbackOccurrences.subtract(claimed)
        windows[windowID] = window
        guard window.selectedOccurrenceBySpace[window.activeSpaceID] != occurrenceID else {
            ensureVisibleSplitOccurrences(in: windowID)
            if claimedFallback { publishOrganizationChange() }
            return
        }
        markViewed(window)
        window.selectedOccurrenceBySpace[window.activeSpaceID] = occurrenceID
        window.revision &+= 1
        windows[windowID] = window
        markViewed(window)
        ensureVisibleSplitOccurrences(in: windowID)
        if claimedFallback { publishOrganizationChange() }
    }

    /// Applies a queued selection only while its captured window/Space authority is current.
    public func selectOccurrence(_ occurrenceID: TabOccurrenceID, from context: BrowserContext) throws {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        try selectOccurrence(occurrenceID, in: context.windowID)
    }

    /// Updates one existing occurrence, including a background tab, in its captured window and Space.
    /// URL metadata does not change selection authority or its revision: unrelated queued selection
    /// commands remain valid. Generation, selection, Space and occurrence ownership are still checked,
    /// and a missing/closed occurrence is never recreated. Destination validation precedes mutation.
    /// Returns false without mutation when the validated destination is already recorded.
    @discardableResult
    public func updateDestination(
        for occurrenceID: TabOccurrenceID, to url: URL, from context: BrowserContext
    ) throws -> Bool {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        guard let tab = tabs[occurrenceID] else { throw BrowserStoreError.tabMissing }
        guard tab.windowID == context.windowID, tab.spaceID == context.spaceID else {
            throw BrowserStoreError.occurrenceOwnedByAnotherWindow
        }
        try BrowserSessionDocument.validateDestination(url)
        guard tab.url != url else { return false }
        tabs[occurrenceID] = BrowserTab(
            id: tab.id, occurrenceID: tab.occurrenceID, windowID: tab.windowID,
            spaceID: tab.spaceID, url: url
        )
        organizationDidUpdateDestination(of: tab.id, to: url)
        return true
    }

    /// Updates metadata for an exact existing occurrence even while another profile is active.
    /// A shell can additionally require its published active context to remain current atomically.
    @discardableResult
    public func updateDestination(
        to url: URL, from authority: BrowserOccurrenceAuthority, validating context: BrowserContext? = nil
    ) throws -> Bool {
        guard authority.storeGeneration == storeGeneration,
              let window = windows[authority.windowID],
              spaces[authority.spaceID]?.profileID == authority.profileID else {
            throw BrowserStoreError.staleContext
        }
        if let context {
            guard context.windowID == authority.windowID, isCurrent(context) else {
                throw BrowserStoreError.staleContext
            }
        }
        guard let tab = tabs[authority.occurrenceID],
              window.occurrenceIDsBySpace[authority.spaceID, default: []].contains(authority.occurrenceID) else {
            throw BrowserStoreError.tabMissing
        }
        guard tab.windowID == authority.windowID, tab.spaceID == authority.spaceID else {
            throw BrowserStoreError.occurrenceOwnedByAnotherWindow
        }
        try BrowserSessionDocument.validateDestination(url)
        guard tab.url != url else { return false }
        tabs[tab.occurrenceID] = BrowserTab(id: tab.id, occurrenceID: tab.occurrenceID,
            windowID: tab.windowID, spaceID: tab.spaceID, url: url)
        organizationDidUpdateDestination(of: tab.id, to: url)
        return true
    }

    /// Closes an occurrence in the captured active Space without closing its window.
    /// Selection moves to the next neighbor, or the previous one at the end.
    public func closeOccurrence(_ occurrenceID: TabOccurrenceID, from context: BrowserContext) throws {
        guard isCurrent(context), let window = windows[context.windowID] else {
            throw BrowserStoreError.staleContext
        }
        guard let tab = tabs[occurrenceID] else { throw BrowserStoreError.tabMissing }
        guard tab.windowID == context.windowID, tab.spaceID == context.spaceID else {
            throw BrowserStoreError.occurrenceOwnedByAnotherWindow
        }
        if case .split? = organization.container(of: .tab(tab.id)) {
            _ = try closeSplitPane(tab.id, from: context)
            return
        }
        try removeOccurrence(occurrenceID, in: window, spaceID: context.spaceID, journalingIn: context)
    }

    /// Closes an exact owned lease, including an inactive Space, only with independent current
    /// window authorization. Inactive replacement selection does not change the active revision.
    public func closeOwnedOccurrenceAndCaptureState(
        _ authority: BrowserOccurrenceAuthority, validating context: BrowserContext
    ) throws -> BrowserWindowState {
        guard isCurrent(context), authority.storeGeneration == storeGeneration,
              authority.windowID == context.windowID, let window = windows[context.windowID],
              spaces[authority.spaceID]?.profileID == authority.profileID else {
            throw BrowserStoreError.staleContext
        }
        guard let tab = tabs[authority.occurrenceID] else { throw BrowserStoreError.tabMissing }
        guard tab.windowID == authority.windowID, tab.spaceID == authority.spaceID else {
            throw BrowserStoreError.occurrenceOwnedByAnotherWindow
        }
        if authority.spaceID == context.spaceID, case .split? = organization.container(of: .tab(tab.id)) {
            return try closeSplitPane(tab.id, from: context)
        }
        try removeOccurrence(authority.occurrenceID, in: window, spaceID: authority.spaceID)
        return try captureWindowState(in: context.windowID)
    }

    /// User closes pass their context so archiving a Today tab is undoable in that window;
    /// engine-initiated closes (`window.close()`) archive without an undo record.
    func removeOccurrence(
        _ occurrenceID: TabOccurrenceID, in capturedWindow: WindowRecord, spaceID: SpaceID,
        journalingIn context: BrowserContext? = nil
    ) throws {
        var window = capturedWindow
        guard window.occurrenceIDsBySpace[spaceID, default: []].contains(occurrenceID) else {
            throw BrowserStoreError.tabMissing
        }
        markViewed(window)
        let wasVisibleSelection = spaceID == window.activeSpaceID
            && window.selectedOccurrenceBySpace[spaceID] == occurrenceID
        detachOccurrence(occurrenceID, from: spaceID, in: &window)
        let closed = tabs.removeValue(forKey: occurrenceID)
        windows[window.id] = window
        markViewed(window)
        if let closed {
            organizationDidClose(closed, wasVisibleSelection: wasVisibleSelection, journalingIn: context)
        }
    }

    /// Membership and replacement selection are resolved by the model in the same actor turn.
    /// Background insertions/removals can preserve context while invalidating a shell's cached order.
    public func closeOccurrenceAndCaptureState(
        _ occurrenceID: TabOccurrenceID, from context: BrowserContext
    ) throws -> BrowserWindowState {
        try closeOccurrence(occurrenceID, from: context)
        return try captureWindowState(in: context.windowID)
    }

    public func snapshot(of windowID: WindowID) throws -> BrowserWindowSnapshot {
        guard let window = windows[windowID] else { throw BrowserStoreError.windowMissing }
        let occurrenceIDs = window.occurrenceIDsBySpace[window.activeSpaceID, default: []]
        return BrowserWindowSnapshot(
            id: windowID,
            activeSpaceID: window.activeSpaceID,
            selectedOccurrenceID: window.selectedOccurrenceBySpace[window.activeSpaceID],
            tabs: occurrenceIDs.compactMap { tabs[$0] },
            revision: window.revision, isStandalone: window.standaloneProfileID != nil
        )
    }
}
