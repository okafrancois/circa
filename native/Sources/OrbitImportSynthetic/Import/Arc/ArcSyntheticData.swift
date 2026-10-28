import BrowserCore
import Foundation
import SQLite3

/// Synthetic Arc data only (port of `test/arc-sidebar.test.cjs` and `test/fixtures/arc-profile.cjs`).
/// Every URL uses the reserved `.test` TLD; titles and names are invented. Used by tests and by
/// `orbit-import synthetic-fixture` for visible lab validation; never derived from a real profile.
public enum ArcSyntheticData {
    public static let directories = ["Default", "Profile 1", "Profile 2"]
    public static let profileNames = ["Default": "Synthetic Default", "Profile 1": "Synthetic Work", "Profile 2": "Synthetic Other"]
    /// Seconds since 1 January 2001, as Arc stores them.
    public static let createdAt = 100.0
    public static let lastActiveAt = 200.0

    public static func profile(_ directory: String) -> Any {
        directory == "Default" ? ["default": [String: Any]()]
            : ["custom": ["_0": ["directoryBasename": directory, "machineID": "synthetic-machine"]]]
    }

    public static func url(_ id: String) -> String { "https://\(id).example.test/" }
    public static func title(_ id: String) -> String { "Synthetic title \(id)" }

    public static func container(_ id: String, _ children: [String] = []) -> [String: Any] {
        ["id": id, "parentID": NSNull(), "childrenIds": children,
         "data": ["itemContainer": ["containerType": ["spaceItems": ["_0": "synthetic-space"]]]]]
    }

    public static func tab(_ id: String, _ parent: String?, url: String? = nil, title: String? = nil) -> [String: Any] {
        ["id": id, "parentID": parent ?? NSNull(), "childrenIds": [String](), "createdAt": createdAt,
         "title": title ?? NSNull(), "unknownItemField": ["nested": true],
         "data": ["tab": ["savedURL": url ?? Self.url(id), "savedTitle": Self.title(id), "timeLastActiveAt": lastActiveAt,
                          "savedMuteStatus": "allowAudio"]]]
    }

    public static func folder(_ id: String, _ parent: String?, _ children: [String], collapsed: Bool = false) -> [String: Any] {
        ["id": id, "parentID": parent ?? NSNull(), "childrenIds": children, "title": "Folder \(id)", "createdAt": createdAt,
         "data": ["list": ["isCollapsed": collapsed]]]
    }

    public static func space(_ id: String, _ directory: String) -> [String: Any] {
        ["id": id, "title": "Space \(id)", "profile": profile(directory),
         "containerIDs": ["pinned", "\(id)-pins", "unpinned", "\(id)-today"],
         "newContainerIDs": [["unpinned": ["_0": ["shared": [String: Any]()]]], "\(id)-today", ["pinned": [String: Any]()], "\(id)-pins"],
         "customInfo": ["iconType": ["emoji_v2": "🧪"],
                        "windowTheme": ["primaryColorPalette": ["tintedLight": ["red": 0.2, "green": 0.4, "blue": 0.6, "alpha": 1, "colorSpace": "sRGB"]],
                                        "futureThemeField": 3]],
         "futureSpaceField": "ignored"]
    }

    public static func pairs(_ records: [[String: Any]]) -> [Any] { records.flatMap { [$0["id"]!, $0] } }

    /// The Electron fixture: storage order differs from sidebar order, nested folders, three
    /// profiles, Favorites per profile, a renamed tab and a collapsed folder.
    public static func items() -> [[String: Any]] {
        [
            tab("a-nested", "inner"), tab("a-today-2", "a-today"), folder("inner", "outer", ["a-nested"], collapsed: true),
            container("a-pins", ["a-pin-2", "outer", "a-pin-1", "a-renamed"]), container("a-today", ["a-today-1", "a-today-2"]),
            tab("a-pin-1", "a-pins"), folder("outer", "a-pins", ["inner"]), tab("a-pin-2", "a-pins"),
            tab("a-renamed", "a-pins", title: "Renamed synthetic tab"),
            tab("a-today-1", "a-today"), container("a-favorites", ["fav-2", "fav-1"]), tab("fav-1", "a-favorites"), tab("fav-2", "a-favorites"),
            container("b-pins", ["b-pin"]), container("b-today", ["b-today-1"]), tab("b-pin", "b-pins"), tab("b-today-1", "b-today"),
            container("c-pins"), container("c-today"), container("b-favorites", ["fav-b"]), tab("fav-b", "b-favorites"), container("c-favorites"),
        ]
    }

    public static func sidebar(items: [[String: Any]] = items(), version: Int = 1) -> [String: Any] {
        ["version": version, "futureTopLevel": ["x": 1],
         "sidebar": ["containers": [["global": [String: Any]()], [
            "spaces": pairs([space("a", "Default"), space("b", "Profile 1"), space("c", "Profile 2")]),
            "topAppsContainerIDs": [profile("Default"), "a-favorites", profile("Profile 1"), "b-favorites", profile("Profile 2"), "c-favorites"],
            "items": pairs(items),
         ]]]]
    }

    /// `todayTabs` extra Today tabs with maximal URLs and titles (about 6 KB each once merged):
    /// 3 000 make a session above the 16 MiB read limit.
    public static func oversizedSidebar(todayTabs: Int = 3_000) -> [String: Any] {
        var items = items()
        let big: [[String: Any]] = (0..<todayTabs).map { index in
            ["id": "big-\(index)", "parentID": "a-today", "childrenIds": [String](), "createdAt": 100.0,
             "title": String(repeating: "T", count: 1_000),
             "data": ["tab": ["savedURL": "https://big.example.test/" + String(repeating: "x", count: 3_960) + "/\(index)",
                              "savedTitle": String(repeating: "S", count: 1_000)]]]
        }
        let today = items.firstIndex { ($0["id"] as! String) == "a-today" }!
        items[today]["childrenIds"] = (items[today]["childrenIds"] as! [String]) + big.map { $0["id"] as! String }
        return sidebar(items: items + big)
    }

    public static func archive() -> [String: Any] {
        ["version": 1, "items": [
            "archive-a", ["archivedAt": 300.0, "source": ["space": ["_0": "a"]], "reason": "manual", "sidebarItem": tab("closed-a", nil)],
            "archive-b", ["archivedAt": 400.0, "source": ["space": ["_0": "b"]], "reason": "automatic", "sidebarItem": tab("closed-b", nil)],
            "archive-neutral", ["archivedAt": 500.0, "source": ["littleArc": [String: Any]()], "reason": "manual", "sidebarItem": tab("closed-neutral", nil)],
        ]]
    }

    public static func localState() -> [String: Any] {
        ["profile": ["info_cache": Dictionary(uniqueKeysWithValues: profileNames.map { ($0.key, ["name": $0.value, "avatar_icon": "x"]) })],
         "browser": ["unrelated": true]]
    }

    public static let historyHosts = ["history-one.example.test", "history-two.example.test"]

    // MARK: Data directory

    public struct HistoryRow: Sendable {
        public var url: String
        public var title = "Synthetic visit"
        /// Microseconds since 1601-01-01 (Chromium).
        public var time: Int64
        public var transition: Int64 = 0
        public var hidden = false

        public init(url: String, title: String = "Synthetic visit", time: Int64, transition: Int64 = 0, hidden: Bool = false) {
            self.url = url
            self.title = title
            self.time = time
            self.transition = transition
            self.hidden = hidden
        }
    }

    public static func chromeTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    public static func historyRows(count: Int, base: Date = Date(timeIntervalSince1970: 1_750_000_000),
                                   distinctPages: Int = 50) -> [HistoryRow] {
        Array(lazyHistoryRows(count: count, base: base, distinctPages: distinctPages))
    }

    /// Generated on demand, so a million-visit fixture does not hold every row in memory.
    public static func lazyHistoryRows(count: Int, base: Date = Date(timeIntervalSince1970: 1_750_000_000),
                                       distinctPages: Int = 50) -> LazyMapSequence<Range<Int>, HistoryRow> {
        let start = chromeTime(base)
        return (0..<count).lazy.map { index in
            HistoryRow(url: "https://\(historyHosts[index % 2])/page/\(index % max(1, distinctPages))",
                       time: start - Int64(index) * 1_000_000, transition: index % 7 == 0 ? 1 : 0)
        }
    }

    public static func writeHistory(_ rows: some Sequence<HistoryRow>, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK, let handle else { throw ArcImportError.historyDatabaseUnreadable }
        defer { sqlite3_close(handle) }
        let schema = """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL,
              typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, from_visit INTEGER,
              transition INTEGER DEFAULT 0 NOT NULL, segment_id INTEGER, visit_duration INTEGER DEFAULT 0 NOT NULL, future_column TEXT);
            CREATE TABLE downloads(id INTEGER PRIMARY KEY, target_path LONGVARCHAR);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(handle, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ArcImportError.historyDatabaseUnreadable }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var insertURL: OpaquePointer?, insertVisit: OpaquePointer?
        sqlite3_prepare_v2(handle, "INSERT INTO urls(url,title,hidden) VALUES(?,?,?)", -1, &insertURL, nil)
        sqlite3_prepare_v2(handle, "INSERT INTO visits(url,visit_time,transition,future_column) VALUES(?,?,?,'x')", -1, &insertVisit, nil)
        defer { sqlite3_finalize(insertURL); sqlite3_finalize(insertVisit) }
        var urlIDs: [String: Int64] = [:]
        for row in rows {
            let key = row.url + (row.hidden ? "#hidden" : "")
            if urlIDs[key] == nil {
                sqlite3_reset(insertURL)
                sqlite3_bind_text(insertURL, 1, row.url, -1, transient)
                sqlite3_bind_text(insertURL, 2, row.title, -1, transient)
                sqlite3_bind_int64(insertURL, 3, row.hidden ? 1 : 0)
                sqlite3_step(insertURL)
                urlIDs[key] = sqlite3_last_insert_rowid(handle)
            }
            sqlite3_reset(insertVisit)
            sqlite3_bind_int64(insertVisit, 1, urlIDs[key]!)
            sqlite3_bind_int64(insertVisit, 2, row.time)
            sqlite3_bind_int64(insertVisit, 3, row.transition)
            sqlite3_step(insertVisit)
        }
        sqlite3_exec(handle, "COMMIT", nil, nil, nil)
    }

    /// `historyVisits` visits per profile over 20 000 distinct pages, generated lazily, for the
    /// first `historyProfiles` profiles (`Default`, `Profile 1`).
    @discardableResult
    public static func writeDataDirectory(at root: URL, historyVisits: Int, historyProfiles: Int = 2) throws -> URL {
        try writeDataDirectory(at: root, historyRows: lazyHistoryRows(count: historyVisits, distinctPages: 20_000),
                               historyProfiles: historyProfiles)
    }

    /// A complete synthetic Arc data directory: sidebar, archive, Local State and History for
    /// `Default` and `Profile 1`. Unrelated Chromium files exist and must never be copied.
    @discardableResult

    public static func writeDataDirectory(at root: URL, historyRows: some Sequence<HistoryRow> = historyRows(count: 30),
                                   sidebar: [String: Any] = sidebar(), historyProfiles: Int = 2) throws -> URL {
        let userData = root.appendingPathComponent("User Data", isDirectory: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: sidebar).write(to: root.appendingPathComponent("StorableSidebar.json"))
        try JSONSerialization.data(withJSONObject: archive()).write(to: root.appendingPathComponent("StorableArchiveItems.json"))
        try JSONSerialization.data(withJSONObject: localState()).write(to: userData.appendingPathComponent("Local State"))
        for (index, directory) in ["Default", "Profile 1"].enumerated() {
            let profile = userData.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            if index < historyProfiles { try writeHistory(historyRows, to: profile.appendingPathComponent("History")) }
            try Data("{\"profile\":{}}".utf8).write(to: profile.appendingPathComponent("Preferences"))
            try Data("synthetic-not-a-cookie-store".utf8).write(to: profile.appendingPathComponent("Cookies"))
            try Data("synthetic-not-a-login-store".utf8).write(to: profile.appendingPathComponent("Login Data"))
        }
        return root
    }

    public static func temporaryDirectory(_ name: String = "orbit-import-synthetic") throws -> URL {
        // The session file store refuses symbolic links in a path (`/var` → `/private/var`).
        let canonical = URL(fileURLWithPath: String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)!))
        let url = canonical.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
