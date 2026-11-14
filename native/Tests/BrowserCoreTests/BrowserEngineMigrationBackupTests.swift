@testable import BrowserCore
import Darwin
import Foundation
import Testing

@Suite("Engine migration backup")
struct BrowserEngineMigrationBackupTests {
    let root: URL
    var engine: URL { root.appendingPathComponent("Chromium", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ relative: String, _ text: String) throws {
        let url = engine.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOf: engine.appendingPathComponent(relative), encoding: .utf8)
    }

    func seedProfiles() throws {
        try write("Local State", "local-1")
        try write("profile-a/Secure Preferences", "secure-a-1")
        try write("profile-a/Preferences", "prefs-a-1")
        try write("profile-a/Network/Cookies", "cookies-a-1")
        try write("profile-a/Network/Cookies-journal", "journal-a-1")
        try write("profile-a/Extensions/abc/1.0_0/manifest.json", "{}")
        try write("profile-b/Secure Preferences", "secure-b-1")
    }

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        _ = lstat(url.path, &info)
        return info.st_mode & 0o777
    }

    @Test("A new build snapshots sign-ins and extension records privately, once")
    func snapshotsOnBuildChange() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try seedProfiles()
        let first = try #require(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: root, engineRoot: engine, build: "0.69.1 (820)"))
        #expect(first.fromBuild == nil && first.toBuild == "0.69.1 (820)")
        #expect(Set(first.files.map(\.path)) == ["Local State", "profile-a/Secure Preferences", "profile-a/Preferences",
                                                 "profile-a/Network/Cookies", "profile-a/Network/Cookies-journal",
                                                 "profile-b/Secure Preferences"])
        let directory = root.appendingPathComponent("EngineMigrationBackups")
        let snapshot = directory.appendingPathComponent(first.id)
        #expect(mode(directory) == 0o700 && mode(snapshot) == 0o700)
        #expect(mode(snapshot.appendingPathComponent("Chromium/profile-a/Network/Cookies")) == 0o600)
        // Extension packages are reinstallable and large; they are not copied.
        #expect(!FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("Chromium/profile-a/Extensions").path))
        #expect(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: root, engineRoot: engine, build: "0.69.1 (820)") == nil)
        let second = try #require(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: root, engineRoot: engine, build: "0.69.2 (830)"))
        #expect(second.fromBuild == "0.69.1 (820)")
        #expect(BrowserEngineMigrationBackup.snapshots(dataRoot: root).map(\.id) == [first.id, second.id])
    }

    @Test("A fresh root records the build without a snapshot")
    func freshRoot() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: root, engineRoot: engine, build: "1 (1)") == nil)
        #expect(BrowserEngineMigrationBackup.snapshots(dataRoot: root).isEmpty)
        try seedProfiles()
        #expect(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: root, engineRoot: engine, build: "1 (1)") == nil)
    }

    @Test("Only the latest build changes are retained and old copies expire")
    func retention() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try seedProfiles()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        for index in 0..<5 {
            _ = try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: root, engineRoot: engine, build: "b\(index)",
                                                              now: start.addingTimeInterval(Double(index) * 60))
        }
        #expect(BrowserEngineMigrationBackup.snapshots(dataRoot: root).map(\.toBuild) == ["b2", "b3", "b4"])
        _ = try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: root, engineRoot: engine, build: "b4",
                                                          now: start.addingTimeInterval(31 * 24 * 3600))
        #expect(BrowserEngineMigrationBackup.snapshots(dataRoot: root).isEmpty)
    }

    @Test("Restore puts the verified copy back and keeps the replaced files")
    func restore() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try seedProfiles()
        let saved = try #require(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: root, engineRoot: engine, build: "old"))
        try write("profile-a/Secure Preferences", "secure-a-reset")
        try write("profile-a/Network/Cookies", "cookies-a-pruned")
        try FileManager.default.removeItem(at: engine.appendingPathComponent("profile-a/Network/Cookies-journal"))
        try write("profile-a/Network/Cookies-wal", "stray-wal")
        try BrowserEngineMigrationBackup.restore(id: saved.id, dataRoot: root, engineRoot: engine)
        #expect(read("profile-a/Secure Preferences") == "secure-a-1")
        #expect(read("profile-a/Network/Cookies") == "cookies-a-1")
        #expect(read("profile-a/Network/Cookies-journal") == "journal-a-1")
        #expect(read("profile-a/Network/Cookies-wal") == nil)
        let safety = try #require(BrowserEngineMigrationBackup.snapshots(dataRoot: root).last)
        #expect(safety.reason == "before-restore")
        let kept = root.appendingPathComponent("EngineMigrationBackups").appendingPathComponent(safety.id)
        #expect(try String(contentsOf: kept.appendingPathComponent("Chromium/profile-a/Secure Preferences"), encoding: .utf8) == "secure-a-reset")
        #expect(try String(contentsOf: kept.appendingPathComponent("Unrestored/profile-a/Network/Cookies-wal"), encoding: .utf8) == "stray-wal")
    }

    @Test("A damaged or unknown snapshot changes nothing")
    func refusesDamage() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try seedProfiles()
        let saved = try #require(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: root, engineRoot: engine, build: "old"))
        try write("profile-a/Secure Preferences", "current")
        let copy = root.appendingPathComponent("EngineMigrationBackups/\(saved.id)/Chromium/profile-a/Secure Preferences")
        try Data("tampered".utf8).write(to: copy)
        #expect(throws: BrowserEngineMigrationBackup.Failure.damagedSnapshot) {
            try BrowserEngineMigrationBackup.restore(id: saved.id, dataRoot: root, engineRoot: engine)
        }
        #expect(throws: BrowserEngineMigrationBackup.Failure.unsafePath) {
            try BrowserEngineMigrationBackup.restore(id: "../x", dataRoot: root, engineRoot: engine)
        }
        #expect(throws: BrowserEngineMigrationBackup.Failure.missingSnapshot) {
            try BrowserEngineMigrationBackup.restore(id: "absent", dataRoot: root, engineRoot: engine)
        }
        #expect(read("profile-a/Secure Preferences") == "current")
        #expect(BrowserEngineMigrationBackup.snapshots(dataRoot: root).count == 1)
    }
}
