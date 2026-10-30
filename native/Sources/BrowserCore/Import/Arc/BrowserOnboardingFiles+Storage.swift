import Foundation

/// The onboarding record is stored like every import state file: private (0700/0600), atomic,
/// through verified descriptors.
extension BrowserOnboardingFiles {
    /// Nil when absent; throws when present but unreadable (never treated as absent).
    public static func load(dataDirectory: URL) throws -> BrowserOnboardingRecord? {
        try ArcImportFiles.readExisting(BrowserOnboardingRecord.self, from: recordFile(dataDirectory: dataDirectory))
    }

    public static func exists(dataDirectory: URL) -> Bool {
        ArcImportFiles.exists(recordFile(dataDirectory: dataDirectory))
            || FileManager.default.fileExists(atPath: recordFile(dataDirectory: dataDirectory).path)
    }

    public static func save(_ record: BrowserOnboardingRecord, dataDirectory: URL) throws {
        try ArcImportFiles.write(record, to: recordFile(dataDirectory: dataDirectory))
    }
}
