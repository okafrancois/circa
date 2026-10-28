@testable import BrowserCore
import Foundation
import Testing

@Suite("source browser import parser and mapping")
struct OrbitImportParserTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func plan(_ graph: ArcSidebarGraph, options: ArcImportOptions = ArcImportOptions(),
                      adopting profile: ProfileID? = nil) -> BrowserImportPlan {
        ArcImportMapper.plan(graph, options: options, defaultProfileTarget: profile, importedAt: now)
    }

    private func titles(_ nodes: [BrowserImportPlan.Node]) -> [String] {
        nodes.flatMap { node -> [String] in
            switch node {
            case let .tab(tab): return [tab.resolvedTitle ?? "?"]
            case let .folder(folder, children): return ["[\(folder.title)]"] + titles(children)
            }
        }
    }

    @Test("Source archive window keys retain profile attribution after product renaming")
    func sourceWindowArchiveProfile() throws {
        let archive: [String: Any] = ["version": 1, "items": [
            "source-window-record", ["archivedAt": 300.0,
                "source": ["littleArc": ["profile": OrbitFixture.profile("Profile 1")]],
                "sidebarItem": OrbitFixture.tab("closed-window", nil)],
        ]]
        let graph = try ArcSidebarParser.parse(sidebar: OrbitFixture.json(OrbitFixture.sidebar()),
            archive: OrbitFixture.json(archive), localState: OrbitFixture.json(OrbitFixture.localState()))
        #expect(graph.archive.first?.profile == .directory("Profile 1"))
    }

    @Test("Alternating arrays, explicit profiles, per-profile Favorites and childrenIds order")
    func sidebarOrder() throws {
        let graph = try OrbitFixture.graph()
        #expect(graph.formatVersion == 1)
        #expect(graph.profiles.map(\.key) == OrbitFixture.directories.map { .directory($0) })
        #expect(graph.profiles.map(\.displayName) == OrbitFixture.directories.map { OrbitFixture.profileNames[$0] })
        let favorites = Dictionary(uniqueKeysWithValues: graph.favorites.map { ($0.profile, $0.tabs.map(\.sourceID)) })
        #expect(favorites[.directory("Default")] == ["fav-2", "fav-1"])
        #expect(favorites[.directory("Profile 1")] == ["fav-b"])
        #expect(favorites[.directory("Profile 2")] == [])
        let a = try #require(graph.spaces.first { $0.sourceID == "a" })
        #expect(a.today.map(\.sourceID) == ["a-today-1", "a-today-2"])
        let mapped = plan(graph)
        let section = try #require(mapped.sections.first)
        #expect(titles(section.pinned) == ["Synthetic title a-pin-2", "[Folder outer]", "[Folder inner]", "Synthetic title a-nested",
                                           "Synthetic title a-pin-1", "Renamed synthetic tab"])
        #expect(mapped.spaces.map(\.name) == ["Space a", "Space b", "Space c"])
        #expect(mapped.profiles.map(\.name) == ["Synthetic Default", "Synthetic Work", "Synthetic Other"])
        #expect(graph.diagnostics.disconnectedItems == 0)
    }

    @Test("Nested folders keep their parent, collapse state, and Space colour, icon and theme")
    func foldersAndAppearance() throws {
        let mapped = plan(try OrbitFixture.graph())
        guard case let .folder(outer, outerChildren)? = mapped.sections[0].pinned.first(where: {
            if case .folder = $0 { return true } else { return false }
        }), case let .folder(inner, innerChildren)? = outerChildren.first else {
            Issue.record("nested folders missing")
            return
        }
        #expect(outer.title == "Folder outer" && !outer.isCollapsed)
        #expect(inner.title == "Folder inner" && inner.isCollapsed)
        #expect(innerChildren.count == 1)
        let appearance = mapped.spaces[0].appearance
        #expect(appearance.colorHex == "#336699")
        #expect(appearance.icon == "🧪")
        let theme = try #require(appearance.theme)
        #expect(OrbitFixture.json(try JSONSerialization.jsonObject(with: Data(theme.utf8)))["futureThemeField"]?.number == 3)
    }

    @Test("Pinned URL vs current URL, custom vs page title, Apple epoch dates and an archive grace period")
    func tabValues() throws {
        let mapped = plan(try OrbitFixture.graph())
        func tabs(_ nodes: [BrowserImportPlan.Node]) -> [BrowserOrganizedTab] {
            nodes.flatMap { node -> [BrowserOrganizedTab] in
                switch node {
                case let .tab(tab): return [tab]
                case let .folder(_, children): return tabs(children)
                }
            }
        }
        let pinned = tabs(mapped.sections[0].pinned)
        let renamed = try #require(pinned.first { $0.customTitle != nil })
        #expect(renamed.customTitle == "Renamed synthetic tab")
        #expect(renamed.pageTitle == "Synthetic title a-renamed")
        #expect(renamed.pinnedURL == URL(string: OrbitFixture.url("a-renamed")))
        // Arc's sidebar stores one saved URL; the live destination starts there.
        #expect(pinned.allSatisfy { $0.pinnedURL == $0.url })
        #expect(pinned.allSatisfy { $0.createdAt == Date(timeIntervalSinceReferenceDate: OrbitFixture.createdAt) })
        let today = mapped.sections[0].today
        #expect(today.allSatisfy { $0.pinnedURL == nil && $0.customTitle == nil })
        #expect(today.allSatisfy { $0.lastActiveAt == now }, "inactivity counts from the import")
        #expect(mapped.favorites[0].tabs.allSatisfy { $0.pinnedURL == $0.url })
        let archived = try #require(mapped.archive.first { $0.tab.pageTitle == "Synthetic title closed-a" })
        #expect(archived.archivedAt == Date(timeIntervalSinceReferenceDate: 300))
        #expect(archived.tab.lastActiveAt == Date(timeIntervalSinceReferenceDate: OrbitFixture.lastActiveAt))
        #expect(archived.reason == .closed && archived.origin == .today && archived.tab.pinnedURL == nil)
        #expect(mapped.archive.first { $0.tab.pageTitle == "Synthetic title closed-b" }?.reason == .automatic)
    }

    @Test("source browser's Default profile merges into the target's first profile; others get stable identities")
    func profileMapping() throws {
        let graph = try OrbitFixture.graph()
        let existing = ProfileID()
        let adopted = plan(graph, adopting: existing)
        #expect(adopted.profiles[0].id == existing && adopted.profiles[0].isAdopted)
        #expect(adopted.spaces[0].profileID == existing && adopted.favorites[0].profileID == existing)
        #expect(adopted.profiles[1].id == ArcImportIdentity().profile(.directory("Profile 1")))
        var separate = ArcImportOptions()
        separate.adoptsDefaultProfile = false
        let distinct = plan(graph, options: separate, adopting: existing)
        #expect(distinct.profiles[0].id == ArcImportIdentity().profile(.directory("Default")))
        #expect(distinct.profiles.allSatisfy { !$0.isAdopted })
        #expect(adopted.historySources.map(\.directory) == ["Default", "Profile 1", "Profile 2"])
    }

    @Test("A legacy opaque profile id maps only through an explicit directory; otherwise a neutral profile")
    func legacyProfiles() throws {
        var sidebar = OrbitFixture.sidebar()
        var root = sidebar["sidebar"] as! [String: Any]
        var containers = root["containers"] as! [Any]
        var container = containers[1] as! [String: Any]
        var spaces = container["spaces"] as! [Any]
        var b = spaces[3] as! [String: Any]
        b["profile"] = ["custom": ["_0": ["id": "synthetic-legacy-id"]]]
        spaces[3] = b
        container["spaces"] = spaces
        containers[1] = container
        root["containers"] = containers
        sidebar["sidebar"] = root
        let unresolved = try OrbitFixture.graph(sidebar: sidebar)
        #expect(unresolved.diagnostics.unresolvedProfiles == 1)
        let neutral = plan(unresolved)
        let neutralProfile = try #require(neutral.profiles.first { $0.sourceDirectory == nil })
        #expect(neutralProfile.name == "Imported Profile")
        #expect(!neutral.historySources.contains { $0.profileID == neutralProfile.id })
        let mapped = plan(try OrbitFixture.graph(sidebar: sidebar, legacy: ["synthetic-legacy-id": "Profile 1"]))
        #expect(mapped.spaces.first { $0.name == "Space b" }?.profileID == ArcImportIdentity().profile(.directory("Profile 1")))
    }

    @Test("Plain dictionaries, legacy containerIDs, records with ids and unknown versions still parse")
    func formatVariants() throws {
        var sidebar = OrbitFixture.sidebar(version: 7)
        var root = sidebar["sidebar"] as! [String: Any]
        var containers = root["containers"] as! [Any]
        var container = containers[1] as! [String: Any]
        var spaces: [String: Any] = [:]
        for space in [OrbitFixture.space("a", "Default"), OrbitFixture.space("b", "Profile 1"), OrbitFixture.space("c", "Profile 2")] {
            var copy = space
            copy.removeValue(forKey: "newContainerIDs")
            spaces[copy["id"] as! String] = copy
        }
        container["spaces"] = spaces
        container["items"] = OrbitFixture.items()   // array of records carrying their ids
        containers[1] = container
        root["containers"] = containers
        sidebar["sidebar"] = root
        let graph = try OrbitFixture.graph(sidebar: sidebar)
        #expect(graph.formatVersion == 7)
        let counts = plan(graph).counts
        #expect(counts.spaces == 3 && counts.pinnedFolders == 2 && counts.pinnedTabs == 5 && counts.todayTabs == 3 && counts.favorites == 3)
        // Without the `sidebar` wrapper (exported variant).
        let unwrapped = try ArcSidebarParser.parse(sidebar: OrbitFixture.json(OrbitFixture.sidebar()["sidebar"]!), archive: nil, localState: nil)
        #expect(unwrapped.spaces.count == 3)
        #expect(throws: ArcImportError.unrecognizedSidebarFormat) {
            try ArcSidebarParser.parse(sidebar: OrbitFixture.json(["version": 1]), archive: nil, localState: nil)
        }
        #expect(throws: ArcImportError.unreadableSourceDocument) { try ArcJSON.parse(Data("{not json".utf8)) }
    }

    @Test("Non-web schemes, credentials, oversized and missing URLs are counted, never turned into searches")
    func urlFiltering() throws {
        var items = OrbitFixture.items()
        let bad = ["file:///tmp/example", "javascript:alert(1)", "data:text/html,x", "chrome://settings/",
                   "https://user:pass@example.test/", "example.test", "https://example.test/" + String(repeating: "x", count: 4096)]
        var extra = bad.enumerated().map { OrbitFixture.tab("bad-\($0.offset)", "a-today", url: $0.element) }
        extra.append(OrbitFixture.tab("blank", "a-today", url: "about:blank"))
        var missing = OrbitFixture.tab("missing", "a-today")
        var data = missing["data"] as! [String: Any]
        var tab = data["tab"] as! [String: Any]
        tab.removeValue(forKey: "savedURL")
        data["tab"] = tab
        missing["data"] = data
        extra.append(missing)
        let index = items.firstIndex { ($0["id"] as! String) == "a-today" }!
        items[index]["childrenIds"] = (items[index]["childrenIds"] as! [String]) + extra.map { $0["id"] as! String }
        let graph = try OrbitFixture.graph(sidebar: OrbitFixture.sidebar(items: items + extra))
        #expect(graph.diagnostics.invalidURLs == bad.count)
        #expect(graph.diagnostics.missingURLs == 1)
        let today = plan(graph).sections[0].today
        #expect(today.contains { $0.url.absoluteString == "about:blank" })
        #expect(today.allSatisfy { ["https", "about"].contains($0.url.scheme) })
    }

    @Test("Cycles, missing and repeated references and duplicate records stay bounded")
    func graphDefects() throws {
        var items = OrbitFixture.items()
        let outer = items.firstIndex { ($0["id"] as! String) == "outer" }!
        items[outer]["childrenIds"] = ["inner", "outer", "absent", "inner"]
        items.append(OrbitFixture.tab("a-pin-1", "a-pins"))
        var sidebar = OrbitFixture.sidebar(items: items)
        // An unpaired trailing key is malformed.
        var root = sidebar["sidebar"] as! [String: Any]
        var containers = root["containers"] as! [Any]
        var container = containers[1] as! [String: Any]
        container["items"] = (container["items"] as! [Any]) + ["unpaired"]
        containers[1] = container
        root["containers"] = containers
        sidebar["sidebar"] = root
        let graph = try OrbitFixture.graph(sidebar: sidebar)
        #expect(graph.diagnostics.cycles == 1)
        #expect(graph.diagnostics.missingReferences == 1)
        #expect(graph.diagnostics.repeatedReferences >= 1)
        #expect(graph.diagnostics.duplicateItems == 1)
        #expect(graph.diagnostics.malformedRecords == 1)
        let mapped = plan(graph)
        #expect(mapped.counts.pinnedTabs == 5)
    }

    @Test("Parent links recover omitted children; disconnected trees are counted, not invented")
    func recovery() throws {
        var items = OrbitFixture.items()
        let today = items.firstIndex { ($0["id"] as! String) == "a-today" }!
        items[today]["childrenIds"] = ["a-today-1"]
        items += [OrbitFixture.tab("orphan-child", "orphan-folder"), OrbitFixture.folder("orphan-folder", nil, ["orphan-child"])]
        let graph = try OrbitFixture.graph(sidebar: OrbitFixture.sidebar(items: items))
        #expect(graph.diagnostics.recoveredParentReferences == 1)
        #expect(graph.spaces[0].today.map(\.sourceID) == ["a-today-1", "a-today-2"])
        #expect(graph.diagnostics.disconnectedItems == 2)
        #expect(!plan(graph).sections.flatMap(\.today).contains { $0.pageTitle == "Synthetic title orphan-child" })
    }

    @Test("Splits and folders in Favorites or Today are flattened and counted")
    func flattening() throws {
        var items = OrbitFixture.items()
        let pins = items.firstIndex { ($0["id"] as! String) == "a-pins" }!
        items[pins]["childrenIds"] = (items[pins]["childrenIds"] as! [String]) + ["split"]
        let favorites = items.firstIndex { ($0["id"] as! String) == "a-favorites" }!
        items[favorites]["childrenIds"] = (items[favorites]["childrenIds"] as! [String]) + ["fav-folder"]
        items += [["id": "split", "parentID": "a-pins", "childrenIds": ["left", "right"],
                   "data": ["splitView": ["orientation": ["vertical": [String: Any]()], "ratio": 0.4]]],
                  OrbitFixture.tab("left", "split"), OrbitFixture.tab("right", "split"),
                  OrbitFixture.folder("fav-folder", "a-favorites", ["fav-3"]), OrbitFixture.tab("fav-3", "fav-folder")]
        let graph = try OrbitFixture.graph(sidebar: OrbitFixture.sidebar(items: items))
        #expect(graph.diagnostics.flattenedSplits == 1)
        #expect(graph.diagnostics.flattenedFolders == 1)
        #expect(graph.favorites[0].tabs.map(\.sourceID) == ["fav-2", "fav-1", "fav-3"])
        #expect(titles(plan(graph).sections[0].pinned).suffix(2) == ["Synthetic title left", "Synthetic title right"])
    }

    @Test("Archives map through their Space; unattributed ones are skipped unless explicitly placed")
    func archiveAttribution() throws {
        let graph = try OrbitFixture.graph()
        #expect(graph.diagnostics.unattributedArchives == 1)
        let skipped = plan(graph)
        #expect(skipped.archive.count == 2 && skipped.skipped.unattributedArchives == 1)
        #expect(skipped.archive.map(\.archivedAt) == skipped.archive.map(\.archivedAt).sorted(by: >))
        let a = skipped.spaces.first { $0.name == "Space a" }!
        #expect(skipped.archive.first { $0.tab.pageTitle == "Synthetic title closed-a" }?.spaceID == a.id)
        var options = ArcImportOptions()
        options.unattributedArchives = .defaultProfile
        let placed = plan(graph, options: options)
        #expect(placed.archive.count == 3)
        #expect(placed.archive.first { $0.tab.pageTitle == "Synthetic title closed-neutral" }?.spaceID == a.id)
        options.includeArchive = false
        options.includeToday = false
        let lean = plan(graph, options: options)
        #expect(lean.archive.isEmpty && lean.skipped.archivedTabsExcluded == 3)
        #expect(lean.counts.todayTabs == 0 && lean.skipped.todayTabsExcluded == 3)
    }

    @Test("Identities are deterministic per source namespace and never contain names or URLs")
    func identities() throws {
        let graph = try OrbitFixture.graph()
        let first = plan(graph), second = ArcImportMapper.plan(graph, defaultProfileTarget: nil, importedAt: now.addingTimeInterval(60))
        #expect(first.spaces.map(\.id) == second.spaces.map(\.id))
        #expect(first.archive.map(\.id) == second.archive.map(\.id))
        #expect(first.favorites.flatMap(\.tabs).map(\.id) == second.favorites.flatMap(\.tabs).map(\.id))
        var other = ArcImportOptions()
        other.namespace = "another-synthetic-source"
        let separated = plan(graph, options: other)
        #expect(Set(separated.spaces.map(\.id)).isDisjoint(with: first.spaces.map(\.id)))
        let uuid = ArcImportIdentity().uuid("tab", ["a-pin-1"])
        #expect(uuid.uuidString.lowercased().wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil)
    }
}
