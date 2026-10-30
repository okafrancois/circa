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

/// The onboarding's navigation and choices, without AppKit. Steps: welcome, import, sync, theme,
/// default browser, finish.
struct OrbitOnboardingFlow: Equatable {
    typealias Step = BrowserOnboardingRecord.Step
    static let steps: [Step] = [.welcome, .importSource, .sync, .theme, .defaultBrowser, .finish]

    private(set) var step: Step
    var importChoice: BrowserOnboardingRecord.ImportChoice?
    var syncChoice: Bool?
    var defaultBrowserChoice: Bool?
    let sources: [OrbitOnboardingSource]
    let syncAvailability: OrbitOnboardingSyncAvailability

    init(step: Step = .welcome, sources: [OrbitOnboardingSource], syncAvailability: OrbitOnboardingSyncAvailability,
         restoring record: BrowserOnboardingRecord? = nil) {
        self.step = step
        self.sources = sources
        self.syncAvailability = syncAvailability
        if let record {
            importChoice = record.importChoice.flatMap { Self.isOffered($0, in: sources) ? $0 : nil }
            syncChoice = record.syncChoice
            defaultBrowserChoice = record.defaultBrowserChoice
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
    var hasBack: Bool { [.sync, .theme, .defaultBrowser].contains(step) }
    var hasSkip: Bool { step == .theme }
    var isCardStep: Bool { step != .welcome }

    var canAdvance: Bool {
        switch step {
        case .welcome, .theme, .finish: true
        case .importSource: importChoice != nil
        case .sync: syncChoice != nil
        case .defaultBrowser: defaultBrowserChoice != nil
        }
    }

    @MainActor var primaryTitle: String {
        step == .finish ? OrbitOnboardingText.getStarted : OrbitOnboardingText.next
    }

    /// The source currently selected on the import step, if any.
    var selectedSource: OrbitOnboardingSource? {
        if case let .browser(id, _) = importChoice { return sources.first { $0.id == id } }
        return nil
    }

    mutating func select(source: OrbitOnboardingSource) {
        importChoice = source.choice(profile: source.profiles.first?.directory)
    }

    mutating func select(profile: String, of source: OrbitOnboardingSource) {
        guard source.profiles.contains(where: { $0.directory == profile }) else { return }
        importChoice = source.choice(profile: profile)
    }

    mutating func selectSync(_ value: Bool) {
        guard !value || syncAvailability == .available else { return }
        syncChoice = value
    }

    @discardableResult
    mutating func advance() -> Bool {
        guard canAdvance, index + 1 < Self.steps.count else { return false }
        step = Self.steps[index + 1]
        return true
    }

    @discardableResult
    mutating func goBack() -> Bool {
        guard hasBack else { return false }
        step = Self.steps[index - 1]
        return true
    }

    func record(_ state: BrowserOnboardingRecord.State, date: Date = Date()) -> BrowserOnboardingRecord {
        BrowserOnboardingRecord(state: state, step: step, date: date, importChoice: importChoice,
                                syncChoice: syncChoice, defaultBrowserChoice: defaultBrowserChoice)
    }
}
