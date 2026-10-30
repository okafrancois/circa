import BrowserCore
import Foundation
import Testing
import Security
@testable import Orbit

struct ArcPasswordPreparationTests {
    private struct Boundary: OrbitRecoverySecItemBoundary {
        let denied: Bool
        func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
            #expect(query[kSecAttrService as String] as? String == "Arc Safe Storage")
            #expect(query[kSecAttrAccount as String] as? String == "Arc")
            return (denied ? errSecUserCanceled : errSecItemNotFound, nil)
        }
        func add(_ attributes: [String: Any]) -> (OSStatus, Any?) { Issue.record("No key may be created"); return (errSecParam, nil) }
    }
    @Test(arguments: [false, true]) func unavailableKeyMakesNoDestinationChange(denied: Bool) throws {
        let base = URL(fileURLWithPath: "/private/tmp/password-key-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Source"), target = base.appendingPathComponent("Target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let configuration = OrbitProductConfiguration(dataRoot: target, secureStorage: .mockKeychain)
        #expect(throws: ArcAuthenticationError.sourceKeyUnavailable) {
            try ArcPasswordImportPreparation.prepare(.init(sourceRoot: source, profiles: []), configuration: configuration,
                keys: ArcSiteSessionKeychain(targetService: "synthetic-target", targetAccount: "synthetic", boundary: Boundary(denied: denied)), probe: BrowserImportRunningProbe(running: { false }))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    @Test func hintRequiresAvailableStore() {
        var report = ArcImportReport(); report.passwordProfiles = [.init(name: "Work", directory: "Profile 1", count: 2), .init(name: "", directory: "Default", count: 0)]
        let available = ArcImportText.confirmation(report, passwordsAvailable: true)
        #expect(available.contains("Coming from Arc? Your Spaces, tabs and passwords come with you, even after Arc stops working."))
        #expect(available.contains("Work: 2 passwords found") && !available.contains("Profile 1:"))
        #expect(available.contains("2 passwords found") && !available.contains("0 passwords found"))
        let unavailable = ArcImportText.confirmation(report, passwordsAvailable: false)
        #expect(!unavailable.contains("tabs and passwords come with you") && !unavailable.contains("passwords found"))
    }
    @Test func profileDisplayNamesAndFolderFallback() {
        var report = ArcImportReport()
        report.passwordProfiles = [.init(name: "Personal", directory: "Default", count: 7),
            .init(name: "", directory: "Profile 1", count: 3)]
        let text = ArcImportText.confirmation(report, passwordsAvailable: true)
        #expect(text.contains("Personal: 7 passwords found") && !text.contains("Default:"))
        #expect(text.contains("Profile 1: 3 passwords found"))
    }

    @Test func localizedCountsOmitZero() {
        var counts = ArcPasswordImportJournal.Counts()
        #expect(ArcPasswordImportText.result(counts, restored: false).isEmpty)
        counts.kept = 1
        #expect(ArcPasswordImportText.result(counts, restored: false) == "1 password not replaced (Circa's version kept)")
        counts.added = 1; counts.alreadyPresent = 2; counts.kept = 3; counts.skipped = 4
        let text = ArcPasswordImportText.result(counts, restored: false)
        #expect(text.contains("1 password added") && !text.contains("1 passwords"))
        #expect(text.contains("2 passwords already in Circa") && text.contains("3 passwords not replaced (Circa's version kept)"))
        #expect(text.contains("4 passwords skipped") && !text.contains("0 "))
    }
}
