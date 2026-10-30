import BrowserCore
import Foundation

/// The sealed import receipt closes the interval between offline publication and the next step record.
enum OrbitOnboardingImportRecovery {
    static func didRestore(configuration: OrbitProductConfiguration) throws {
        guard var record = try BrowserOnboardingFiles.load(dataDirectory: configuration.dataRoot), record.state == .started,
              case .browser = record.importChoice else { return }
        record.step = .importSource
        record.importApplied = false; record.importDuration = nil; record.importSummary = nil
        record.importChoice = BrowserOnboardingRecord.ImportChoice.none
        record.selectedProfiles = []; record.favourites = nil; record.favouritesSkipped = false
        try BrowserOnboardingFiles.save(record, dataDirectory: configuration.dataRoot)
    }

    static func reconcile(_ status: BrowserAuthenticationRun.Status, configuration: OrbitProductConfiguration) throws {
        guard var record = try BrowserOnboardingFiles.load(dataDirectory: configuration.dataRoot), record.state == .started,
              case let .browser(sourceID, profile) = record.importChoice, sourceID == status.sourceID else { return }
        let selected = Set(record.selectedProfiles ?? profile.map { [$0] } ?? [])
        guard selected == Set(status.sourceProfiles) else { return }
        if status.phase == .passwordsPending, record.importApplied != true {
            record.importApplied = true
            record.importDuration = status.importDuration
            try BrowserOnboardingFiles.save(record, dataDirectory: configuration.dataRoot)
        } else if status.phase == .restored, record.importApplied == true {
            try didRestore(configuration: configuration)
        }
    }
}
