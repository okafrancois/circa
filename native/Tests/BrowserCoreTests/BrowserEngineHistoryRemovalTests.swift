@testable import BrowserCore
import Darwin
import Foundation
import SQLite3
import Testing

@Suite("Engine history removal routing")
struct BrowserEngineHistoryRemovalTests {
    @Test("Each shell deletion maps to the engine removal of the same scope")
    func routing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let visit = BrowserHistoryVisit(url: URL(string: "https://synthetic.test/page")!, visitedAt: now)
        let range = DateInterval(start: now.addingTimeInterval(-86400), end: now)
        #expect(BrowserEngineHistoryRemoval.routing(.visit(visit.id), visit: visit) == .visit(url: visit.url, visitedAt: now))
        // Without the row (already gone) or with another row, there is nothing to match.
        #expect(BrowserEngineHistoryRemoval.routing(.visit(visit.id)) == nil)
        #expect(BrowserEngineHistoryRemoval.routing(.visit(UUID()), visit: visit) == nil)
        #expect(BrowserEngineHistoryRemoval.routing(.interval(range)) == .interval(range))
        #expect(BrowserEngineHistoryRemoval.routing(.interval(DateInterval(start: now, duration: 0))) == nil)
        #expect(BrowserEngineHistoryRemoval.routing(.lastHour(now: now)) == .period(.lastHour))
        #expect(BrowserEngineHistoryRemoval.routing(.lastDay(now: now)) == .period(.lastDay))
        #expect(BrowserEngineHistoryRemoval.routing(.all) == .period(.allTime))
        #expect(BrowserEngineHistoryRemoval.routing(.site("Sub.Synthetic.TEST")) == .host("sub.synthetic.test"))
        #expect(BrowserEngineHistoryRemoval.routing(.site("[::1]")) == .host("::1"))
        #expect(BrowserEngineHistoryRemoval.routing(.site("")) == nil)
        #expect(BrowserEngineHistoryRemoval.Period.allCases.map(\.duration) == [3600, 86400, nil])
    }

    @Test("The history page filter carries exactly the removal's scope")
    func historyPageFilter() {
        let start = Date(timeIntervalSince1970: 1_800_000_000.25)
        let end = start.addingTimeInterval(3600)
        let hour = BrowserEngineHistoryRemoval.period(.lastHour).historyPageFilter(now: end)
        #expect(hour["kind"] as? String == "since")
        #expect(hour["begin"] as? Double == 1_800_000_000_250)
        let day = BrowserEngineHistoryRemoval.period(.lastDay).historyPageFilter(now: end)
        #expect(day["begin"] as? Double == 1_799_917_200_250.0)
        #expect(BrowserEngineHistoryRemoval.period(.allTime).historyPageFilter() as? [String: String] == ["kind": "all"])
        let interval = BrowserEngineHistoryRemoval.interval(DateInterval(start: start, end: end)).historyPageFilter()
        #expect(interval["kind"] as? String == "interval")
        #expect(interval["begin"] as? Double == 1_800_000_000_250)
        #expect(interval["end"] as? Double == 1_800_003_600_250)
        let host = BrowserEngineHistoryRemoval.host("synthetic.test").historyPageFilter()
        #expect(host as? [String: String] == ["kind": "host", "host": "synthetic.test"])
        let url = BrowserEngineHistoryRemoval.url(URL(string: "https://synthetic.test/a?b=1")!).historyPageFilter()
        #expect(url as? [String: String] == ["kind": "url", "url": "https://synthetic.test/a?b=1"])
        let visit = BrowserEngineHistoryRemoval.visit(url: URL(string: "https://synthetic.test/a")!, visitedAt: start).historyPageFilter()
        #expect(visit["kind"] as? String == "visit")
        #expect(visit["at"] as? Double == 1_800_000_000_250)
        #expect(visit["tolerance"] as? Double == 120_000)
        #expect(visit["begin"] as? Double == 1_799_999_880_250.0)
        // Encodes as a JSON literal the page script receives.
        #expect((try? JSONSerialization.data(withJSONObject: visit)) != nil)
    }
}

@Suite("Engine migration backup site pruning")
struct BrowserEngineMigrationBackupSiteTests {
    let root: URL
    var dataRoot: URL { root.appendingPathComponent("Orbit", isDirectory: true) }
    var engine: URL { dataRoot.appendingPathComponent("Chromium", isDirectory: true) }
    let profile = ProfileID()
    let other = ProfileID()

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/orbit-backup-site-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func name(_ id: ProfileID) -> String { BrowserEngineProfileCache.directoryName(id) }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    func cookieDatabase(_ url: URL, hosts: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        var sql = "CREATE TABLE cookies(host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL);"
        for (index, host) in hosts.enumerated() {
            sql += "INSERT INTO cookies VALUES('\(host)','c\(index)','synthetic-secret-\(index)');"
        }
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }

    func hosts(_ url: URL) throws -> [String] {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        try #require(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(database, "SELECT host_key FROM cookies ORDER BY host_key", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(String(cString: sqlite3_column_text(statement, 0))) }
        return result
    }

    func snapshotFile(_ manifest: BrowserEngineMigrationBackup.Manifest, _ relative: String) -> URL {
        dataRoot.appendingPathComponent("EngineMigrationBackups/" + manifest.id + "/Chromium/" + relative)
    }

    @Test("A per-site clear removes only that site's cookies from the backups, which still restore")
    func pruneSite() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let siteHosts = ["synthetic.test", ".synthetic.test", "www.synthetic.test", ".Deep.Sub.Synthetic.test"]
        let keptHosts = ["notsynthetic.test", "synthetic.test.example", "other.example"]
        for id in [profile, other] {
            try Data("prefs".utf8).write(to: engine.appendingPathComponent(name(id) + "/Preferences").creatingParent())
            try cookieDatabase(engine.appendingPathComponent(name(id) + "/Network/Cookies"), hosts: siteHosts + keptHosts)
        }
        // A stale journal copy beside the profile's database.
        try Data("stale-journal synthetic-secret".utf8).write(to: engine.appendingPathComponent(name(profile) + "/Network/Cookies-journal"))
        let manifest = try #require(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: dataRoot, engineRoot: engine, build: "1 (1)"))
        let copy = snapshotFile(manifest, name(profile) + "/Network/Cookies")

        #expect(try BrowserEngineMigrationBackup.prune(profile: profile, .site("synthetic.test"), dataRoot: dataRoot) == 1)
        #expect(try hosts(copy) == keptHosts.sorted())
        #expect(!exists(snapshotFile(manifest, name(profile) + "/Network/Cookies-journal")))
        // No freed page keeps a deleted value.
        let bytes = try Data(contentsOf: copy)
        for index in siteHosts.indices { #expect(bytes.range(of: Data("synthetic-secret-\(index)".utf8)) == nil) }
        // The other profile is untouched.
        #expect(try hosts(snapshotFile(manifest, name(other) + "/Network/Cookies")) == (siteHosts + keptHosts).sorted())
        let current = try #require(BrowserEngineMigrationBackup.snapshots(dataRoot: dataRoot).first)
        #expect(!current.files.contains { $0.path == name(profile) + "/Network/Cookies-journal" })
        #expect(current.files.contains { $0.path == name(profile) + "/Network/Cookies" })
        #expect(try BrowserEngineMigrationBackup.prune(profile: profile, .site("synthetic.test"), dataRoot: dataRoot) == 0)
        // The edited snapshot still verifies and restores.
        try BrowserEngineMigrationBackup.restore(id: manifest.id, dataRoot: dataRoot, engineRoot: engine)
        #expect(try hosts(engine.appendingPathComponent(name(profile) + "/Network/Cookies")) == keptHosts.sorted())
    }

    @Test("A cookie copy that cannot be edited is dropped rather than kept")
    func pruneSiteFallsBackToDroppingCookies() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("prefs".utf8).write(to: engine.appendingPathComponent(name(profile) + "/Preferences").creatingParent())
        try Data("not a database synthetic.test".utf8).write(to: engine.appendingPathComponent(name(profile) + "/Network/Cookies").creatingParent())
        let manifest = try #require(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: dataRoot, engineRoot: engine, build: "1 (1)"))
        #expect(try BrowserEngineMigrationBackup.prune(profile: profile, .site("synthetic.test"), dataRoot: dataRoot) == 1)
        #expect(!exists(snapshotFile(manifest, name(profile) + "/Network/Cookies")))
        #expect(exists(snapshotFile(manifest, name(profile) + "/Preferences")))
        let current = try #require(BrowserEngineMigrationBackup.snapshots(dataRoot: dataRoot).first)
        #expect(current.files.map(\.path).sorted() == [name(profile) + "/Preferences"])
    }
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
