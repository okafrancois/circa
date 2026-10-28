import Foundation

public enum BrowserLinkMatch: String, Codable, CaseIterable, Sendable {
    case contains, equals, host
}

public struct BrowserLinkRoute: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var match: BrowserLinkMatch
    public var value: String
    public var spaceID: SpaceID

    public init(id: UUID = UUID(), match: BrowserLinkMatch = .contains, value: String, spaceID: SpaceID) {
        self.id = id
        self.match = match
        self.value = value
        self.spaceID = spaceID
    }

    public var isValid: Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    public func matches(_ url: URL) -> Bool {
        guard isValid, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        switch match {
        case .contains: return url.absoluteString.contains(value)
        case .equals: return url.absoluteString == value
        case .host: return url.host?.caseInsensitiveCompare(value) == .orderedSame
        }
    }
}

public enum BrowserLinkDefaultDestination: Codable, Equatable, Hashable, Sendable {
    case quickWindow, mostRecentSpace, space(SpaceID)
}

/// Shared across browser windows and profiles. Order is explicit: the first matching route wins.
public struct BrowserLinkRouting: Codable, Equatable, Sendable {
    public var rules: [BrowserLinkRoute] = []
    public var defaultDestination: BrowserLinkDefaultDestination = .quickWindow
    public init() {}

    public func destination(for url: URL, availableSpaces: Set<SpaceID>) -> BrowserLinkDefaultDestination {
        if let route = rules.first(where: { availableSpaces.contains($0.spaceID) && $0.matches(url) }) {
            return .space(route.spaceID)
        }
        if case .space(let id) = defaultDestination, !availableSpaces.contains(id) { return .mostRecentSpace }
        return defaultDestination
    }

    mutating func removeSpaces(_ ids: Set<SpaceID>) {
        rules.removeAll { ids.contains($0.spaceID) }
        if case .space(let id) = defaultDestination, ids.contains(id) { defaultDestination = .mostRecentSpace }
    }
}

extension BrowserSettingsStore {
    public func saveLinkRoute(_ route: BrowserLinkRoute) throws {
        guard route.isValid else { throw BrowserLinkRoutingError.invalidRule }
        try updateLinkRouting { routing in
            if let index = routing.rules.firstIndex(where: { $0.id == route.id }) { routing.rules[index] = route }
            else { routing.rules.append(route) }
        }
    }

    public func removeLinkRoute(_ id: UUID) throws {
        try updateLinkRouting { $0.rules.removeAll { $0.id == id } }
    }

    public func moveLinkRoute(_ id: UUID, offset: Int) throws {
        try updateLinkRouting { routing in
            guard let index = routing.rules.firstIndex(where: { $0.id == id }),
                  routing.rules.indices.contains(index + offset) else { return }
            routing.rules.swapAt(index, index + offset)
        }
    }

    public func setLinkDefaultDestination(_ destination: BrowserLinkDefaultDestination) throws {
        try updateLinkRouting { $0.defaultDestination = destination }
    }
}

public enum BrowserLinkRoutingError: Error { case invalidRule }
