import Foundation

extension CodingUserInfoKey {
    /// A `Date` used to stamp tabs created by migrating a version 1 document.
    public static let browserSessionMigrationDate = CodingUserInfoKey(rawValue: "OrbitBrowserSessionMigrationDate")!
}

extension BrowserSessionDocument {
    // Version 3 → 4 (Space themes) is additive and lossless: every version 3 field decodes unchanged,
    // Spaces start without a theme (`BrowserSpace.theme == nil`, so the legacy Settings palette or the
    // default theme still applies) and no imported appearance is marked as migrated. A version 4
    // document must declare `themeImports`, even empty. Versions above `currentVersion` are refused.

    /// Version 1 → 2. Version 1 stored only per-window occurrence lists. Each logical tab becomes a
    /// Today tab of its Space, in first-appearance order (windows in document order, then each
    /// Space's occurrence order); Favorites, Pinned, folders and archive start empty.
    /// Lossless for profiles, Spaces, windows, active Spaces, occurrence identities and order,
    /// selections and destinations. Version 1 permitted one `TabID` in several Spaces or twice in
    /// one window, which version 2 forbids; only those later occurrences receive a new `TabID`,
    /// derived deterministically from the old one and their occurrence identity. Every identity of
    /// the version 1 file is reserved first: a derived identity that would equal another tab's (or
    /// one derived earlier) is derived again with the next attempt number, so two independent tabs
    /// can never merge, whatever the claim order.
    static func migratedOrganization(
        spaces: [BrowserSpace], windows: [Window], tabs: [BrowserTab], date: Date
    ) -> (tabs: [BrowserTab], organization: BrowserOrganizationDocument) {
        var tabsByOccurrence: [TabOccurrenceID: BrowserTab] = [:]
        for tab in tabs where tabsByOccurrence[tab.occurrenceID] == nil { tabsByOccurrence[tab.occurrenceID] = tab }
        var visited: Set<TabOccurrenceID> = []
        var homeSpace: [TabID: SpaceID] = [:]
        var claimingWindows: [TabID: Set<WindowID>] = [:]
        var entries: [TabID: BrowserOrganizedTab] = [:]
        var today: [SpaceID: [BrowserOrganizationNode]] = [:]
        var remapped: [TabOccurrenceID: TabID] = [:]
        var reserved = Set(tabs.map(\.id))

        func claim(_ tab: BrowserTab) {
            guard visited.insert(tab.occurrenceID).inserted else { return }
            var id = tab.id
            if let home = homeSpace[id], home != tab.spaceID || claimingWindows[id, default: []].contains(tab.windowID) {
                var attempt = 0
                repeat {
                    id = derivedTabID(tab.id, tab.occurrenceID, attempt: attempt)
                    attempt += 1
                } while reserved.contains(id)
                reserved.insert(id)
                remapped[tab.occurrenceID] = id
            }
            if homeSpace[id] == nil {
                homeSpace[id] = tab.spaceID
                entries[id] = BrowserOrganizedTab(id: id, url: tab.url, createdAt: date, lastActiveAt: date)
                today[tab.spaceID, default: []].append(.tab(id))
            }
            claimingWindows[id, default: []].insert(tab.windowID)
        }

        for window in windows {
            for group in window.spaces {
                for occurrenceID in group.occurrenceIDs {
                    if let tab = tabsByOccurrence[occurrenceID] { claim(tab) }
                }
            }
        }
        // Occurrences no window references are kept so validation reports them as orphans.
        for tab in tabs { claim(tab) }

        let migratedTabs = tabs.map { tab in
            remapped[tab.occurrenceID].map {
                BrowserTab(id: $0, occurrenceID: tab.occurrenceID, windowID: tab.windowID, spaceID: tab.spaceID, url: tab.url)
            } ?? tab
        }
        var orderedSpaces = spaces.map(\.id).filter { today[$0] != nil }
        let known = Set(orderedSpaces)
        orderedSpaces += today.keys.filter { !known.contains($0) }.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        let organization = BrowserOrganizationDocument(
            tabs: entries.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString },
            folders: [], favorites: [],
            spaces: orderedSpaces.map { .init(spaceID: $0, pinned: [], today: today[$0] ?? []) },
            archive: [], archivePolicy: BrowserArchivePolicy())
        return (migratedTabs, organization)
    }

    /// XOR of both identities with RFC 4122 version 4 bits, so repeated migrations agree. Later
    /// attempts, used only after a collision, additionally mix every byte with the attempt number.
    static func derivedTabID(_ tabID: TabID, _ occurrenceID: TabOccurrenceID, attempt: Int = 0) -> TabID {
        var left = tabID.rawValue.uuid
        let right = occurrenceID.rawValue.uuid
        withUnsafeMutableBytes(of: &left) { target in
            withUnsafeBytes(of: right) { source in
                for index in 0..<16 { target[index] ^= source[index] }
            }
            if attempt > 0 {
                // SplitMix64 over both halves, seeded by the attempt: deterministic and well spread.
                var state = UInt64(attempt) &* 0x9E37_79B9_7F4A_7C15
                for half in 0..<2 {
                    var word: UInt64 = 0
                    for offset in 0..<8 { word = word << 8 | UInt64(target[half * 8 + offset]) }
                    state &+= word &+ 0x9E37_79B9_7F4A_7C15
                    var mixed = state
                    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
                    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
                    mixed ^= mixed >> 31
                    for offset in 0..<8 { target[half * 8 + offset] = UInt8(truncatingIfNeeded: mixed >> (56 - 8 * offset)) }
                }
            }
            target[6] = (target[6] & 0x0F) | 0x40
            target[8] = (target[8] & 0x3F) | 0x80
        }
        return TabID(UUID(uuid: left))
    }
}
