import Foundation

/// First-run onboarding state, `Onboarding/onboarding.json` in the data directory. Only a data
/// directory that was empty at launch ever receives one; its presence alone keeps every later
/// launch out of the first-run surfaces (onboarding and the first-run import offer).
public struct BrowserOnboardingRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case started, completed }

    public enum Step: String, Codable, Sendable, CaseIterable {
        case welcome, importSource, favourites, sync, theme, defaultBrowser, finish
    }

    /// The source chosen on the import step; it is applied before the first runtime window opens.
    public enum ImportChoice: Codable, Equatable, Sendable {
        case none
        /// A detected source (`BrowserImportDescriptor.id`) and, when it has profiles, one of them.
        case browser(sourceID: String, profileDirectory: String?)
    }

    public var version = 1
    public var state: State
    public var step: Step
    public var date: Date
    public var importChoice: ImportChoice?
    public var syncChoice: Bool?
    public var defaultBrowserChoice: Bool?
    public var selectedProfiles: [String]?
    public var favourites: [BrowserOnboardingFavourite]?
    public var importDuration: Double?
    public var importApplied: Bool?
    public var favouritesSkipped: Bool?
    public var importSummary: ImportSummary?

    public struct ImportSummary: Codable, Equatable, Sendable {
        public let spaces: Int
        public let pinnedTabs: Int
        public let passwords: Int
        public init(spaces: Int, pinnedTabs: Int, passwords: Int) {
            self.spaces = spaces; self.pinnedTabs = pinnedTabs; self.passwords = passwords
        }
    }

    public init(state: State, step: Step, date: Date = Date(), importChoice: ImportChoice? = nil,
                syncChoice: Bool? = nil, defaultBrowserChoice: Bool? = nil) {
        self.state = state
        self.step = step
        self.date = date
        self.importChoice = importChoice
        self.syncChoice = syncChoice
        self.defaultBrowserChoice = defaultBrowserChoice
    }
}

/// What a launch does about onboarding. Decided once, from the launch-time state of the data
/// directory and the record; never from files written by this run.
public enum BrowserOnboardingDecision: Equatable, Sendable {
    case none
    /// Show the onboarding at `step`; `resumed` when an earlier run started it.
    case show(BrowserOnboardingRecord.Step, resumed: Bool)

    /// `admitted`: the build and launch options may show onboarding at all (product identity,
    /// default session, or an explicit synthetic opt-in). `fresh`: the data directory held no Orbit
    /// data when the launch began.
    public static func decide(admitted: Bool, record: BrowserOnboardingRecord?, recordUnreadable: Bool = false,
                              fresh: Bool) -> BrowserOnboardingDecision {
        guard admitted, !recordUnreadable else { return .none }
        if let record {
            return record.state == .started ? .show(record.step, resumed: true) : .none
        }
        return fresh ? .show(.welcome, resumed: false) : .none
    }
}

public enum BrowserOnboardingFiles {
    public static func directory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("Onboarding", isDirectory: true)
    }

    public static func recordFile(dataDirectory: URL) -> URL {
        directory(dataDirectory: dataDirectory).appendingPathComponent("onboarding.json")
    }

    // Reading and writing share the import's verified private-file storage (its extension).
}

/// An Orbit data directory is fresh when none of the files and folders an earlier Orbit run leaves
/// behind exist. Checked before this launch writes anything; the engine root is checked by the
/// launcher before the engine starts, because the engine populates it immediately.
public enum BrowserOnboardingEligibility {
    /// Sidecars of the session file (`<session>.<suffix>`), every one a sign of an earlier run.
    public static let sessionSidecars = [
        "settings.json", "shortcuts.json", "sync.json", "downloads.json", "site-permissions.json",
        "site-preferences.json", "profile-removals.json"
    ]
    /// Folders an earlier run creates; any entry inside marks the directory as used.
    public static let dataFolders = [
        "Import", "History", "Boosts", "Favorite Icons", "SessionImport", "AuthenticationImport", "Onboarding"
    ]

    public static func isFresh(sessionFile: URL, engineRootHadData: Bool,
                               fileManager: FileManager = .default) -> Bool {
        guard !engineRootHadData else { return false }
        let directory = sessionFile.deletingLastPathComponent()
        func exists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }
        if exists(sessionFile) { return false }
        for suffix in sessionSidecars where exists(sessionFile.appendingPathExtension(suffix)) { return false }
        for folder in dataFolders {
            let url = directory.appendingPathComponent(folder, isDirectory: true)
            guard exists(url) else { continue }
            let entries = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? ["unreadable"]
            if !entries.isEmpty { return false }
        }
        return true
    }

    /// Before the engine starts: does its root already hold data from an earlier run?
    public static func directoryHasEntries(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        let entries = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? ["unreadable"]
        return !entries.isEmpty
    }
}
