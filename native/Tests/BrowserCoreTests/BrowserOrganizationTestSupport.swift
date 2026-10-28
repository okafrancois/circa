import Foundation
@testable import BrowserCore

/// Deterministic wall clock injected into the store.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

func organizationURL(_ path: String) -> URL { URL(string: "https://organization.test/\(path)")! }

/// Two synthetic profiles: Personal owns Home and Leisure, Work owns Lab. Two windows show Home.
struct OrganizationFixture: Sendable {
    let store: BrowserStore
    let clock: ManualClock
    let personal: ProfileID
    let work: ProfileID
    let home: SpaceID
    let leisure: SpaceID
    let lab: SpaceID
    let window: WindowID
    let other: WindowID

    static func make() async throws -> OrganizationFixture {
        let clock = ManualClock()
        let store = BrowserStore(clock: { clock.now })
        let personal = await store.createProfile(name: "Synthetic Personal")
        let work = await store.createProfile(name: "Synthetic Work")
        let home = try await store.createSpace(name: "Home", profileID: personal)
        let leisure = try await store.createSpace(name: "Leisure", profileID: personal)
        let lab = try await store.createSpace(name: "Lab", profileID: work)
        let window = try await store.createWindow(activeSpaceID: home)
        let other = try await store.createWindow(activeSpaceID: home)
        return OrganizationFixture(store: store, clock: clock, personal: personal, work: work,
                                   home: home, leisure: leisure, lab: lab, window: window, other: other)
    }

    func context(_ windowID: WindowID? = nil) async throws -> BrowserContext {
        try await store.captureContext(in: windowID ?? window)
    }

    /// Opens a new tab and returns its logical identity.
    @discardableResult
    func open(_ path: String, in windowID: WindowID? = nil, activate: Bool = true) async throws -> TabID {
        let target = windowID ?? window
        let occurrenceID = try await store.openTab(url: organizationURL(path), from: context(target), activate: activate)
        return try await occurrence(occurrenceID, in: target).id
    }

    func occurrence(_ id: TabOccurrenceID, in windowID: WindowID) async throws -> BrowserTab {
        let document = await store.sessionDocument()
        guard let tab = document.tabs.first(where: { $0.occurrenceID == id && $0.windowID == windowID }) else {
            throw BrowserStoreError.tabMissing
        }
        return tab
    }

    /// Occurrences of `tabID` in a window, across all of its Spaces.
    func occurrences(of tabID: TabID, in windowID: WindowID? = nil) async -> [BrowserTab] {
        let target = windowID ?? window
        return await store.sessionDocument().tabs.filter { $0.id == tabID && $0.windowID == target }
    }

    func organization(_ windowID: WindowID? = nil) async throws -> BrowserOrganizationSnapshot {
        try await store.organizationSnapshot(from: context(windowID))
    }

    func activate(_ spaceID: SpaceID, in windowID: WindowID? = nil) async throws {
        try await store.activateSpace(spaceID, in: windowID ?? window)
    }

    /// Full document validation, including occurrence/logical-tab invariants.
    func validate() async throws {
        try await store.sessionDocument().validate()
    }
}

extension BrowserOrganizationSnapshot {
    var todayIDs: [TabID] { today.compactMap(\.node.tabID) }
    var favoriteIDs: [TabID] { favorites.compactMap(\.node.tabID) }
    var pinnedNodes: [BrowserOrganizationNode] { pinned.map(\.node) }

    func folder(_ id: FolderID) -> BrowserOrganizationFolderItem? {
        guard case let .folder(folder)? = item(for: .folder(id)) else { return nil }
        return folder
    }
}

extension BrowserOrganizationFolderItem {
    var childNodes: [BrowserOrganizationNode] { children.map(\.node) }
}
