@testable import BrowserCore
import Darwin
import Foundation
import Testing

@Suite("Engine profile leftovers")
struct BrowserEngineProfileLeftoversTests {
    let root: URL
    var support: URL { root.appendingPathComponent("Library/Application Support", isDirectory: true) }
    var caches: URL { root.appendingPathComponent("Library/Caches", isDirectory: true) }
    var dataRoot: URL { support.appendingPathComponent("Orbit", isDirectory: true) }
    var engine: URL { dataRoot.appendingPathComponent("Chromium", isDirectory: true) }
    var cacheRoot: URL { caches.appendingPathComponent("Orbit/Chromium", isDirectory: true) }
    let removed = ProfileID()
    let kept = ProfileID()

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/orbit-profile-leftovers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ url: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    func name(_ id: ProfileID) -> String { BrowserEngineProfileCache.directoryName(id) }

    func seedCaches() throws {
        for id in [removed, kept] {
            try write(cacheRoot.appendingPathComponent(name(id) + "/Cache/Cache_Data/index"))
            try write(cacheRoot.appendingPathComponent(name(id) + "/Code Cache/js/index"))
        }
        try write(cacheRoot.appendingPathComponent("Default/Cache/Cache_Data/index"))
    }

    @Test("The cache root mirrors a personal data root under Caches, and nothing else")
    func cacheRootResolution() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(BrowserEngineProfileCache.cacheRoot(engineRoot: engine, applicationSupport: support, caches: caches) == cacheRoot)
        // Synthetic and laboratory roots keep caches inside their profile directories.
        let synthetic = root.appendingPathComponent("synthetic/data/Chromium")
        #expect(BrowserEngineProfileCache.cacheRoot(engineRoot: synthetic, applicationSupport: support, caches: caches) == nil)
        // Never Caches itself or a direct child of it shared with other applications.
        #expect(BrowserEngineProfileCache.cacheRoot(engineRoot: support, applicationSupport: support, caches: caches) == nil)
        #expect(BrowserEngineProfileCache.cacheRoot(engineRoot: dataRoot, applicationSupport: support, caches: caches) == nil)
        // A lexical escape is refused rather than resolved.
        let escape = URL(fileURLWithPath: support.path + "/Orbit/../../../Chromium")
        #expect(BrowserEngineProfileCache.cacheRoot(engineRoot: escape, applicationSupport: support, caches: caches) == nil)
        #expect(BrowserEngineProfileCache.directoryName(removed) == "profile-" + removed.rawValue.uuidString.lowercased())
        #expect(BrowserEngineProfileCache.profileID(directoryName: name(removed)) == removed)
        #expect(BrowserEngineProfileCache.profileID(directoryName: "Default") == nil)
        #expect(BrowserEngineProfileCache.profileID(directoryName: "profile-" + removed.rawValue.uuidString) == nil)
    }

    @Test("Removing a profile deletes only its own cache directory")
    func removesOwnCacheOnly() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try seedCaches()
        let outside = caches.appendingPathComponent("Other/" + name(removed) + "/index")
        try write(outside)
        try BrowserEngineProfileCache.remove(removed, cacheRoot: cacheRoot)
        #expect(!exists(cacheRoot.appendingPathComponent(name(removed))))
        #expect(exists(cacheRoot.appendingPathComponent(name(kept) + "/Cache/Cache_Data/index")))
        #expect(exists(cacheRoot.appendingPathComponent("Default/Cache/Cache_Data/index")))
        #expect(exists(outside))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).sorted() == ["Default", name(kept)].sorted())
        // Idempotent; a missing cache root is not an error.
        try BrowserEngineProfileCache.remove(removed, cacheRoot: cacheRoot)
        try BrowserEngineProfileCache.remove(removed, cacheRoot: root.appendingPathComponent("absent"))
    }

    @Test("Links are unlinked, never followed, and a linked cache root is refused")
    func linksAreNotFollowed() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("precious/file")
        try write(target)
        try FileManager.default.createDirectory(at: cacheRoot.appendingPathComponent(name(removed)), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cacheRoot.appendingPathComponent(name(removed) + "/Cache"),
                                                   withDestinationURL: target.deletingLastPathComponent())
        try BrowserEngineProfileCache.remove(removed, cacheRoot: cacheRoot)
        #expect(exists(target) && !exists(cacheRoot.appendingPathComponent(name(removed))))

        let linkedRoot = root.appendingPathComponent("linked-caches")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target.deletingLastPathComponent())
        try write(target.deletingLastPathComponent().appendingPathComponent(name(kept) + "/index"))
        #expect(throws: BrowserEngineProfileCache.Failure.unsafePath) {
            try BrowserEngineProfileCache.remove(kept, cacheRoot: linkedRoot)
        }
        #expect(exists(target.deletingLastPathComponent().appendingPathComponent(name(kept) + "/index")))
    }

    @Test("A deferred removal is finished by the launch sweep, which keeps live profiles")
    func launchSweep() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try seedCaches()
        // The engine still has the kept profile; the removed one's directory is gone.
        try write(engine.appendingPathComponent(name(kept) + "/Preferences"))
        try write(engine.appendingPathComponent("Default/Preferences"))
        // A retired tree from a removal cut short in an earlier run.
        try write(cacheRoot.appendingPathComponent(BrowserEngineProfileCache.retiredPrefix + "profile-old-1234/Cache/index"))
        #expect(try BrowserEngineProfileCache.sweep(cacheRoot: cacheRoot, engineRoot: engine) == 1)
        #expect(!exists(cacheRoot.appendingPathComponent(name(removed))))
        #expect(exists(cacheRoot.appendingPathComponent(name(kept) + "/Cache/Cache_Data/index")))
        #expect(try BrowserEngineProfileCache.purgeRetired(cacheRoot: cacheRoot) == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).sorted() == ["Default", name(kept)].sorted())
        #expect(try BrowserEngineProfileCache.sweep(cacheRoot: cacheRoot, engineRoot: engine) == 0)
        #expect(try BrowserEngineProfileCache.sweep(cacheRoot: root.appendingPathComponent("absent"), engineRoot: engine) == 0)
    }

    // MARK: Migration backups

    func seedBackup() throws -> BrowserEngineMigrationBackup.Manifest {
        try write(engine.appendingPathComponent("Local State"))
        for id in [removed, kept] {
            try write(engine.appendingPathComponent(name(id) + "/Preferences"), "prefs")
            try write(engine.appendingPathComponent(name(id) + "/Network/Cookies"), "cookies")
            try write(engine.appendingPathComponent(name(id) + "/Network/Cookies-journal"), "journal")
        }
        return try #require(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: dataRoot, engineRoot: engine, build: "1 (1)"))
    }

    func snapshotFile(_ manifest: BrowserEngineMigrationBackup.Manifest, _ relative: String) -> URL {
        dataRoot.appendingPathComponent("EngineMigrationBackups/" + manifest.id + "/Chromium/" + relative)
    }

    @Test("Clearing a profile's site data drops only its cookie copies")
    func pruneCookies() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try seedBackup()
        #expect(try BrowserEngineMigrationBackup.prune(profile: removed, .cookies, dataRoot: dataRoot) == 1)
        let current = try #require(BrowserEngineMigrationBackup.snapshots(dataRoot: dataRoot).first)
        #expect(Set(current.files.map(\.path)) == ["Local State", name(removed) + "/Preferences", name(kept) + "/Preferences",
                                                   name(kept) + "/Network/Cookies", name(kept) + "/Network/Cookies-journal"])
        #expect(!exists(snapshotFile(manifest, name(removed) + "/Network/Cookies")))
        #expect(!exists(snapshotFile(manifest, name(removed) + "/Network/Cookies-journal")))
        #expect(exists(snapshotFile(manifest, name(removed) + "/Preferences")))
        #expect(exists(snapshotFile(manifest, name(kept) + "/Network/Cookies")))
        #expect(try BrowserEngineMigrationBackup.prune(profile: removed, .cookies, dataRoot: dataRoot) == 0)
        // The pruned snapshot still restores.
        try BrowserEngineMigrationBackup.restore(id: manifest.id, dataRoot: dataRoot, engineRoot: engine)
    }

    @Test("Removing a profile drops all of its copies; a launch prune catches removed profiles")
    func pruneProfiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try seedBackup()
        #expect(try BrowserEngineMigrationBackup.prune(profile: removed, .allFiles, dataRoot: dataRoot) == 1)
        #expect(!exists(snapshotFile(manifest, name(removed))))
        #expect(exists(snapshotFile(manifest, name(kept) + "/Network/Cookies")))
        let current = try #require(BrowserEngineMigrationBackup.snapshots(dataRoot: dataRoot).first)
        #expect(!current.files.contains { $0.path.hasPrefix(name(removed)) })

        // The kept profile disappears from the engine root without a prune (crash mid-removal).
        try FileManager.default.removeItem(at: engine.appendingPathComponent(name(kept)))
        #expect(try BrowserEngineMigrationBackup.pruneRemovedProfiles(dataRoot: dataRoot, engineRoot: engine) == 1)
        #expect(!exists(snapshotFile(manifest, name(kept))))
        let last = try #require(BrowserEngineMigrationBackup.snapshots(dataRoot: dataRoot).first)
        #expect(last.files.map(\.path) == ["Local State"])
        // A missing engine root keeps every recovery copy.
        try FileManager.default.removeItem(at: engine)
        #expect(try BrowserEngineMigrationBackup.pruneRemovedProfiles(dataRoot: dataRoot, engineRoot: engine) == 0)
        #expect(BrowserEngineMigrationBackup.snapshots(dataRoot: dataRoot).count == 1)
    }

    @Test("A snapshot holding nothing but the removed profile is deleted")
    func emptySnapshotIsDeleted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(engine.appendingPathComponent(name(removed) + "/Preferences"))
        try write(engine.appendingPathComponent(name(removed) + "/Cookies"))
        _ = try #require(try BrowserEngineMigrationBackup.prepareLaunch(dataRoot: dataRoot, engineRoot: engine, build: "1 (1)"))
        #expect(try BrowserEngineMigrationBackup.prune(profile: removed, .allFiles, dataRoot: dataRoot) == 1)
        #expect(BrowserEngineMigrationBackup.snapshots(dataRoot: dataRoot).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dataRoot.appendingPathComponent("EngineMigrationBackups").path).isEmpty)
    }
}
