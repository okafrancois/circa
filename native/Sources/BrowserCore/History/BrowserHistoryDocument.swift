import Foundation

public enum BrowserHistoryPolicy: Sendable {
    case persistent, ephemeral, `private`
}

public enum BrowserHistoryTransition: String, Codable, Sendable {
    case link, typed, reload, backForward, redirect, imported, unknown
}

/// Import adapters must convert Chrome's epoch/microseconds and transitions before submission.
/// IDs must be stable across retries; the destination profile is bound by the document.
public struct BrowserHistoryDocument: Codable, Sendable {
    public let version: Int
    public let profileID: ProfileID
    public let visits: [BrowserHistoryVisit]

    public init(profileID: ProfileID, visits: [BrowserHistoryVisit]) {
        version = 1
        self.profileID = profileID
        self.visits = visits
    }
}

public struct BrowserHistoryVisit: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public var title: String
    public let visitedAt: Date
    public let transition: BrowserHistoryTransition
    public let redirectChain: [URL]
    public var faviconReference: URL?
    public let typedCount: Int

    public init(id: UUID = UUID(), url: URL, title: String = "", visitedAt: Date = Date(),
                transition: BrowserHistoryTransition = .unknown, redirectChain: [URL] = [],
                faviconReference: URL? = nil, typedCount: Int = 0) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.transition = transition
        self.redirectChain = redirectChain
        self.faviconReference = faviconReference
        self.typedCount = max(0, typedCount)
    }
}

public struct BrowserHistorySuggestion: Equatable, Sendable {
    public let profileID: ProfileID
    public let url: URL
    public let title: String
    public let faviconReference: URL?
    public let visitCount: Int
    public let typedCount: Int
    public let lastVisitedAt: Date
    public let score: Double
}

/// Engine-owned PNG bytes can travel with history without fetching a site's icon in another
/// profile. Existing HTTP(S) metadata references remain readable, but never trigger UI requests.
public enum BrowserHistoryFavicon {
    public static func reference(png: Data) -> URL? {
        guard !png.isEmpty, png.count <= 131_072,
              png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        return URL(string: "data:image/png;base64," + png.base64EncodedString())
    }

    public static func accepts(_ url: URL) -> Bool {
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url.host != nil && url.user == nil && url.password == nil
        }
        let text = url.absoluteString
        let prefix = "data:image/png;base64,"
        guard text.utf8.count <= 180_000, text.hasPrefix(prefix),
              let data = Data(base64Encoded: String(text.dropFirst(prefix.count))) else { return false }
        return reference(png: data) != nil
    }
}

public struct BrowserHistoryDay: Sendable {
    public let day: Date
    public let visits: [BrowserHistoryVisit]
}

public enum BrowserHistorySearchMode: Sendable { case prefix, substring }
public enum BrowserHistoryDeletion: Sendable {
    case visit(UUID)
    /// Half-open interval: start <= visit < end.
    case interval(DateInterval)
    case lastHour(now: Date)
    case lastDay(now: Date)
    /// Exact normalized host, including all schemes/ports; subdomains remain distinct.
    case site(String)
    case all
}

public enum BrowserHistoryError: Error, Equatable {
    case storageFailure(Int32)
    case profileMismatch
    case unsupportedVersion
    case invalidVisit
    case closed
    case temporarilyUnavailable
}

/// Maintenance follows a committed mutation and never changes its success result.
public enum BrowserHistoryMaintenanceStatus: Equatable, Sendable {
    case idle
    case complete
    case checkpointDeferred(Int32)
}
