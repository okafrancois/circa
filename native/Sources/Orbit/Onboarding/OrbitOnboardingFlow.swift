import AppKit
import BrowserCore

/// A browser the import step offers, with its profiles (metadata only).
struct OrbitOnboardingSource: Equatable, Sendable {
    struct Profile: Equatable, Sendable {
        let directory: String
        let name: String
    }

    /// `BrowserImportDescriptor.id` of the detected source.
    let id: String
    let name: String
    let bundleIdentifier: String?
    let profiles: [Profile]

    func choice(profile: String?) -> BrowserOnboardingRecord.ImportChoice {
        .browser(sourceID: id, profileDirectory: profile)
    }
}

/// iCloud availability as the sync step explains it.
enum OrbitOnboardingSyncAvailability: Equatable, Sendable {
    case available, signedOut, unavailable
}

/// The onboarding's navigation and choices, without AppKit. Steps: welcome, import, favourites, sync, theme,
/// default browser, finish.
struct OrbitOnboardingFlow: Equatable {
    typealias Step = BrowserOnboardingRecord.Step
    static let steps: [Step] = [.welcome, .importSource, .favourites, .sync, .theme, .defaultBrowser, .finish]

    private(set) var step: Step
    var importChoice: BrowserOnboardingRecord.ImportChoice?
    var syncChoice: Bool?
    var defaultBrowserChoice: Bool?
    var selectedProfiles: Set<String> = []
    var favourites = BrowserOnboardingFavourite.starter
    var importDuration: Double?
    var importSummary: BrowserOnboardingRecord.ImportSummary?
    var importApplied = false
    var favouritesSkipped = false
    let sources: [OrbitOnboardingSource]
    let syncAvailability: OrbitOnboardingSyncAvailability

    init(step: Step = .welcome, sources: [OrbitOnboardingSource], syncAvailability: OrbitOnboardingSyncAvailability,
         restoring record: BrowserOnboardingRecord? = nil) {
        self.step = step
        self.sources = sources
        self.syncAvailability = syncAvailability
        if let record {
            importChoice = record.importChoice.flatMap { record.importApplied == true || Self.isOffered($0, in: sources) ? $0 : nil }
            syncChoice = record.syncChoice
            defaultBrowserChoice = record.defaultBrowserChoice
            selectedProfiles = Set(record.selectedProfiles ?? [])
            favourites = record.favourites ?? BrowserOnboardingFavourite.starter
            importDuration = record.importDuration
            importSummary = record.importSummary
            importApplied = record.importApplied == true
            favouritesSkipped = record.favouritesSkipped == true
        }
        if selectedProfiles.isEmpty, record?.selectedProfiles == nil, case let .browser(_, profile) = importChoice, let profile {
            selectedProfiles = [profile]
        }
        // A single possible answer is preselected; the reference keeps Next disabled until a choice.
        if sources.isEmpty, importChoice == nil { importChoice = BrowserOnboardingRecord.ImportChoice.none }
        if syncAvailability != .available { syncChoice = false }
    }

    static func isOffered(_ choice: BrowserOnboardingRecord.ImportChoice, in sources: [OrbitOnboardingSource]) -> Bool {
        switch choice {
        case .none: return true
        case let .browser(id, profile):
            guard let source = sources.first(where: { $0.id == id }) else { return false }
            return profile == nil ? source.profiles.isEmpty : source.profiles.contains { $0.directory == profile }
        }
    }

    var index: Int { Self.steps.firstIndex(of: step) ?? 0 }
    var skippedSteps: Set<Step> { importsSpaceConfiguration ? [.favourites, .theme] : [] }
    var effectiveSteps: [Step] { Self.steps.filter { !skippedSteps.contains($0) } }
    var hasBack: Bool { step != .welcome && step != .finish && !importApplied }
    var selectedFavourites: [BrowserOnboardingFavourite] { favourites.filter(\.selected) }
    var hasSkip: Bool { [.importSource, .favourites, .theme].contains(step) }
    var isCardStep: Bool { step != .welcome && step != .finish }

    var canAdvance: Bool {
        switch step {
        case .welcome, .favourites, .theme, .finish: true
        case .importSource: importChoice != nil && (selectedSource?.profiles.isEmpty != false || !selectedProfiles.isEmpty)
        case .sync: syncChoice != nil
        case .defaultBrowser: defaultBrowserChoice != nil
        }
    }

    @MainActor var primaryTitle: String {
        step == .finish ? OrbitOnboardingText.getStarted : step == .importSource ? OrbitOnboardingText.bringOver : OrbitOnboardingText.next
    }

    /// The source currently selected on the import step, if any.
    var selectedSource: OrbitOnboardingSource? {
        if case let .browser(id, _) = importChoice { return sources.first { $0.id == id } }
        return nil
    }

    mutating func select(source: OrbitOnboardingSource) {
        importChoice = source.choice(profile: source.profiles.first?.directory)
        selectedProfiles = Set(source.profiles.map(\.directory))
    }

    mutating func select(profile: String, of source: OrbitOnboardingSource) {
        guard source.profiles.contains(where: { $0.directory == profile }) else { return }
        if selectedProfiles.contains(profile) { selectedProfiles.remove(profile) } else { selectedProfiles.insert(profile) }
        importChoice = source.choice(profile: source.profiles.first { selectedProfiles.contains($0.directory) }?.directory)
    }

    mutating func selectSync(_ value: Bool) {
        guard !value || syncAvailability == .available else { return }
        syncChoice = value
    }

    @discardableResult
    mutating func advance() -> Bool {
        guard canAdvance, let i = effectiveSteps.firstIndex(of: step), i + 1 < effectiveSteps.count else { return false }
        step = effectiveSteps[i + 1]
        return true
    }

    @discardableResult
    mutating func goBack() -> Bool {
        guard hasBack else { return false }
        guard let i = effectiveSteps.firstIndex(of: step), i > 0 else { return false }
        step = effectiveSteps[i - 1]
        return true
    }

    func record(_ state: BrowserOnboardingRecord.State, date: Date = Date()) -> BrowserOnboardingRecord {
        var record = BrowserOnboardingRecord(state: state, step: step, date: date, importChoice: importChoice,
                                syncChoice: syncChoice, defaultBrowserChoice: defaultBrowserChoice)
        record.selectedProfiles = selectedProfiles.sorted()
        record.favourites = favourites
        record.importDuration = importDuration
        record.importSummary = importSummary
        record.importApplied = importApplied
        record.favouritesSkipped = favouritesSkipped
        return record
    }
}
