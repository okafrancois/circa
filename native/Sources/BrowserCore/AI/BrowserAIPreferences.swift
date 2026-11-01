import Foundation

/// What each default model is used for.
public enum BrowserAIUse: String, Codable, CaseIterable, Sendable {
    /// Tab titles, downloads, link previews, writing help.
    case quick
    /// Command Bar, Assistant panel, Find.
    case chat
    /// Tasks that act on pages.
    case errands
}

public struct BrowserAIModelChoice: Codable, Hashable, Sendable {
    public var provider: BrowserAIProviderID
    public var model: String?
    public var effort: String?
    public init(provider: BrowserAIProviderID, model: String? = nil, effort: String? = nil) {
        self.provider = provider
        self.model = model
        self.effort = effort
    }
}

/// Helper switches are stored now; Settings shows a helper's row only once its feature ships.
public struct BrowserAIHelperPreferences: Codable, Equatable, Sendable {
    public var linkPreviewSummaries = true
    public var tidyTitlesAndDownloads = true
    public var tidyToday = true
    public var askInFind = true
    public var writingHelp = true
    public init() {}
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        linkPreviewSummaries = try values.decodeIfPresent(Bool.self, forKey: .linkPreviewSummaries) ?? true
        tidyTitlesAndDownloads = try values.decodeIfPresent(Bool.self, forKey: .tidyTitlesAndDownloads) ?? true
        tidyToday = try values.decodeIfPresent(Bool.self, forKey: .tidyToday) ?? true
        askInFind = try values.decodeIfPresent(Bool.self, forKey: .askInFind) ?? true
        writingHelp = try values.decodeIfPresent(Bool.self, forKey: .writingHelp) ?? true
    }
}

/// Device-local AI choices. Not part of the iCloud sync projection: installed programs differ
/// per Mac. Everything is off until the user turns AI on.
public struct BrowserAIPreferences: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var readsCurrentTabOnRequest = true
    /// Registrable hosts where AI never reads or acts, normalized by `BrowserAIPolicy.site(from:)`.
    public var disabledSites: [String] = []
    public var defaultModels: [BrowserAIUse: BrowserAIModelChoice] = [:]
    public var helpers = BrowserAIHelperPreferences()
    public init() {}

    private enum CodingKeys: String, CodingKey { case isEnabled, readsCurrentTabOnRequest, disabledSites, defaultModels, helpers }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        readsCurrentTabOnRequest = try values.decodeIfPresent(Bool.self, forKey: .readsCurrentTabOnRequest) ?? true
        disabledSites = (try? values.decodeIfPresent([String].self, forKey: .disabledSites)) ?? []
        // Unknown providers or uses from a newer version are dropped, not fatal.
        let models = (try? values.decodeIfPresent([String: BrowserAIModelChoice].self, forKey: .defaultModels)) ?? [:]
        defaultModels = Dictionary(uniqueKeysWithValues: models.compactMap { key, value in BrowserAIUse(rawValue: key).map { ($0, value) } })
        helpers = (try? values.decodeIfPresent(BrowserAIHelperPreferences.self, forKey: .helpers)) ?? .init()
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(readsCurrentTabOnRequest, forKey: .readsCurrentTabOnRequest)
        try values.encode(disabledSites, forKey: .disabledSites)
        try values.encode(Dictionary(uniqueKeysWithValues: defaultModels.map { ($0.key.rawValue, $0.value) }), forKey: .defaultModels)
        try values.encode(helpers, forKey: .helpers)
    }
}

/// Where AI may read or act. Later surfaces must ask this before sending any page content.
public enum BrowserAIPolicy {
    /// Private windows are always off; the per-site list and the master switch apply everywhere.
    public static func allowsPageAccess(_ preferences: BrowserAIPreferences, isPrivate: Bool, host: String?) -> Bool {
        guard preferences.isEnabled, preferences.readsCurrentTabOnRequest, !isPrivate else { return false }
        guard let host = host.flatMap(site(from:)) else { return true }
        return !preferences.disabledSites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// "https://www.Example.com/path" and "example.com" both become "example.com".
    public static func site(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let host = URL(string: text)?.host(percentEncoded: false)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty, host.count <= 253,
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-.".unicodeScalars.contains($0) }) else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public static func adding(_ input: String, to sites: [String]) -> [String]? {
        guard let site = site(from: input) else { return nil }
        return sites.contains(site) ? sites : sites + [site]
    }

    /// The model used when the user has not chosen one: the first ready program that is not at
    /// its limit, in the order Settings lists them.
    public static func automaticChoice(for use: BrowserAIUse, statuses: [BrowserAIProviderID: BrowserAIProviderStatus]) -> BrowserAIModelChoice? {
        choices(for: use, statuses: statuses).first { choice in
            guard let state = statuses[choice.provider]?.state, state.isReady else { return false }
            return state.usage?.limitReached != true
        }
    }

    /// Every choice offered for a use, programs that cannot run included (Settings shows them
    /// disabled with the reason).
    public static func choices(for use: BrowserAIUse, statuses: [BrowserAIProviderID: BrowserAIProviderStatus]) -> [BrowserAIModelChoice] {
        let codex = statuses[.codex]?.models ?? []
        let codexDefault = codex.first(where: \.isDefault) ?? codex.first
        let claude = statuses[.claudeCode]?.models.isEmpty == false ? statuses[.claudeCode]!.models : BrowserAIClaudeLaunch.models
        func claudeChoice(_ id: String, effort: String? = nil) -> BrowserAIModelChoice? {
            claude.contains { $0.id == id } ? BrowserAIModelChoice(provider: .claudeCode, model: id, effort: effort) : nil
        }
        func codexChoices(effort: String?) -> [BrowserAIModelChoice] {
            codex.map { model in
                BrowserAIModelChoice(provider: .codex, model: model.id,
                                     effort: effort.flatMap { model.efforts.contains($0) ? $0 : nil })
            }
        }
        switch use {
        case .quick:
            var result = [BrowserAIModelChoice(provider: .onDevice)]
            if let codexDefault { result.append(BrowserAIModelChoice(provider: .codex, model: codexDefault.id,
                effort: codexDefault.efforts.contains("low") ? "low" : nil)) }
            result += [claudeChoice("haiku")].compactMap { $0 }
            return result
        case .chat:
            return codexChoices(effort: nil) + ["fable", "opus", "sonnet", "haiku"].compactMap { claudeChoice($0) }
        case .errands:
            return codexChoices(effort: "high") + ["fable", "opus"].compactMap { claudeChoice($0, effort: "high") }
        }
    }
}

/// The system model's availability, mapped to the provider states Settings shows.
public enum BrowserAIOnDeviceAvailability: Equatable, Sendable {
    case available
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case systemTooOld

    public var state: BrowserAIProviderState {
        switch self {
        case .available: .ready(BrowserAIAccount(plan: nil))
        case .appleIntelligenceNotEnabled: .unavailable(.appleIntelligenceOff)
        case .deviceNotEligible: .unavailable(.deviceNotEligible)
        case .modelNotReady: .unavailable(.modelNotReady)
        case .systemTooOld: .unavailable(.systemTooOld)
        }
    }
}
