import Foundation
import Testing
@testable import BrowserCore

/// First-run onboarding: eligibility of data directories shaped like earlier installs, the launch
/// decision and the private record.
struct BrowserOnboardingTests {
    private func root() throws -> URL {
        let base = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(base) }
        let url = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("orbit-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Files every launch creates before the environment opens, never markers.
        FileManager.default.createFile(atPath: url.appendingPathComponent(".orbit-instance.lock").path, contents: Data())
        FileManager.default.createFile(atPath: url.appendingPathComponent(".orbit-synthetic-root").path, contents: Data("{}".utf8))
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Chromium"), withIntermediateDirectories: true)
        return url
    }

    private func write(_ relative: String, in root: URL, _ contents: String = "{}") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// Layouts written by earlier releases (same file set from v0.24 through v0.28; later ones add sidecars).
    private func shapedRoot(_ version: String) throws -> URL {
        let url = try root()
        let profile = UUID().uuidString
        try write("session.json", in: url, #"{"version":2,"windows":[],"spaces":[],"profiles":[]}"#)
        try write("session.json.settings.json", in: url)
        try write("session.json.downloads.json", in: url)
        try write("History/\(profile)/history.sqlite", in: url, "sqlite")
        try write("Favorite Icons/icons.json", in: url)
        try write("Chromium/profile-\(profile)/Preferences", in: url)
        try write("Chromium/Local State", in: url)
        if version >= "0.27" {
            try write("session.json.sync.json", in: url)
            try write("session.json.shortcuts.json", in: url)
            try write("Boosts/\(profile).json", in: url)
        }
        if version >= "0.28" {
            try write("Import/import-state.json", in: url)
            try write("session.json.site-permissions.json", in: url)
            try write("session.json.site-preferences.json", in: url)
        }
        return url
    }

    private func fresh(_ url: URL) -> Bool {
        BrowserOnboardingEligibility.isFresh(
            sessionFile: url.appendingPathComponent("session.json"),
            engineRootHadData: BrowserOnboardingEligibility.directoryHasEntries(url.appendingPathComponent("Chromium")))
    }

    @Test("Migration matrix: only an empty data directory is fresh")
    func migrationMatrix() throws {
        for version in ["0.24.1", "0.27.2", "0.28.2"] {
            let url = try shapedRoot(version)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(!fresh(url), "v\(version)-shaped root must not show onboarding")
        }
        let empty = try root()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(fresh(empty))
        for single in ["session.json", "session.json.settings.json", "session.json.sync.json", "session.json.shortcuts.json",
                       "session.json.downloads.json", "Import/import-state.json", "Import/Backups/backup.json",
                       "History/x/history.sqlite", "Boosts/x.json"] {
            let url = try root()
            defer { try? FileManager.default.removeItem(at: url) }
            try write(single, in: url)
            #expect(!fresh(url), "\(single) alone marks an existing install")
        }
        // An empty Import/ or Chromium/ (created before the first save) is still fresh; any engine data is not.
        let folders = try root()
        defer { try? FileManager.default.removeItem(at: folders) }
        try FileManager.default.createDirectory(at: folders.appendingPathComponent("Import"), withIntermediateDirectories: true)
        #expect(fresh(folders))
        try write("Chromium/Local State", in: folders)
        #expect(!fresh(folders))
    }

    @Test("Decision: admission first, a started record resumes, a completed one never shows again")
    func decision() {
        let started = BrowserOnboardingRecord(state: .started, step: .theme)
        let completed = BrowserOnboardingRecord(state: .completed, step: .finish)
        #expect(BrowserOnboardingDecision.decide(admitted: true, record: nil, fresh: true) == .show(.welcome, resumed: false))
        #expect(BrowserOnboardingDecision.decide(admitted: true, record: nil, fresh: false) == .none)
        #expect(BrowserOnboardingDecision.decide(admitted: false, record: nil, fresh: true) == .none)
        #expect(BrowserOnboardingDecision.decide(admitted: true, record: started, fresh: false) == .show(.theme, resumed: true))
        #expect(BrowserOnboardingDecision.decide(admitted: true, record: completed, fresh: true) == .none)
        #expect(BrowserOnboardingDecision.decide(admitted: true, record: nil, recordUnreadable: true, fresh: true) == .none)
        #expect(BrowserOnboardingDecision.decide(admitted: false, record: started, fresh: true) == .none)
    }

    @Test("The record is private, round-trips its choices and is never confused with absence")
    func record() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try BrowserOnboardingFiles.load(dataDirectory: url) == nil)
        #expect(!BrowserOnboardingFiles.exists(dataDirectory: url))
        let record = BrowserOnboardingRecord(state: .started, step: .sync, date: Date(timeIntervalSince1970: 1_800_000_000),
                                             importChoice: .browser(sourceID: "chrome", profileDirectory: "Profile 1"),
                                             syncChoice: true, defaultBrowserChoice: nil)
        try BrowserOnboardingFiles.save(record, dataDirectory: url)
        #expect(try BrowserOnboardingFiles.load(dataDirectory: url) == record)
        #expect(BrowserOnboardingFiles.exists(dataDirectory: url))
        let file = BrowserOnboardingFiles.recordFile(dataDirectory: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int ?? 0) & 0o077 == 0)
        let folder = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect((folder[.posixPermissions] as? Int ?? 0) & 0o077 == 0)
        // A record makes the directory used for every later decision.
        #expect(!fresh(url))
        try Data("not json".utf8).write(to: file)
        #expect(throws: (any Error).self) { try BrowserOnboardingFiles.load(dataDirectory: url) }
        for choice in [BrowserOnboardingRecord.ImportChoice.none, .browser(sourceID: "safari", profileDirectory: nil)] {
            var copy = record
            copy.importChoice = choice
            try BrowserOnboardingFiles.save(copy, dataDirectory: url)
            #expect(try BrowserOnboardingFiles.load(dataDirectory: url)?.importChoice == choice)
        }
    }
}
