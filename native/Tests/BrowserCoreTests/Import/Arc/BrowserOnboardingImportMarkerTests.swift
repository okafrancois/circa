import Foundation
import Testing
@testable import BrowserCore

/// Arc import state files mark an existing install for the first-run onboarding.
struct BrowserOnboardingImportMarkerTests {
    @Test("An Arc import offer, journal or ledger alone keeps a data directory from being fresh")
    func arcImportFilesAreMarkers() throws {
        let base = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(base) }
        for pick in 0..<3 {
            let root = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("orbit-onboarding-arc-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let location = ArcImportDataLocation(sessionFile: root.appendingPathComponent("session.json"))
            try FileManager.default.createDirectory(at: location.importDirectory, withIntermediateDirectories: true)
            #expect(BrowserOnboardingEligibility.isFresh(sessionFile: location.sessionFile, engineRootHadData: false))
            let file = [location.offerFile, location.journalFile, location.ledgerFile][pick]
            try Data("{}".utf8).write(to: file)
            #expect(!BrowserOnboardingEligibility.isFresh(sessionFile: location.sessionFile, engineRootHadData: false))
        }
    }
}
