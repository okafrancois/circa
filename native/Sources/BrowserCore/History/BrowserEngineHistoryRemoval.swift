import Foundation

/// What an engine with its own history store must drop after a shell history deletion, so a
/// deleted visit does not survive in the engine's history, visited-link, top-site, favicon,
/// shortcut or predictor stores (those follow the engine's history deletions).
///
/// Built from a `BrowserHistoryDeletion` before the shell deletes its rows (a single visit needs
/// its row's URL and time). Never logged with its URLs or hosts.
public enum BrowserEngineHistoryRemoval: Equatable, Sendable {
    /// A period ending now (the last hour, the last day, all time).
    case period(Period)
    /// Visits whose time lies in the half-open interval `start <= time < end`.
    case interval(DateInterval)
    /// Every visit to an exact host (all schemes and ports; subdomains stay distinct).
    case host(String)
    /// Every visit to an exact URL.
    case url(URL)
    /// The engine's visits to `url` recorded within `tolerance` of `visitedAt`.
    case visit(url: URL, visitedAt: Date)

    public enum Period: Sendable, CaseIterable {
        case lastHour, lastDay, allTime

        /// How far back the period reaches; nil for all time.
        public var duration: TimeInterval? {
            switch self {
            case .lastHour: 3600
            case .lastDay: 86400
            case .allTime: nil
            }
        }
    }

    /// The engine records its own visit a moment before or after the shell does.
    public static let visitTolerance: TimeInterval = 120

    /// The engine removal matching a shell deletion. `visit` is the row a `.visit` deletion
    /// targets, read before the deletion; without it there is nothing to match.
    public static func routing(_ deletion: BrowserHistoryDeletion, visit: BrowserHistoryVisit? = nil) -> Self? {
        switch deletion {
        case .visit(let id):
            guard let visit, visit.id == id else { return nil }
            return .visit(url: visit.url, visitedAt: visit.visitedAt)
        case .interval(let interval): return interval.duration > 0 ? .interval(interval) : nil
        case .lastHour: return .period(.lastHour)
        case .lastDay: return .period(.lastDay)
        case .site(let host):
            let normalized = normalizedHost(host)
            return normalized.isEmpty ? nil : .host(normalized)
        case .all: return .period(.allTime)
        }
    }

    /// The filter a history page applies: times in milliseconds since 1970, hosts lowercased
    /// without IPv6 brackets, URLs compared after URL parsing on both sides. A period starts at
    /// `now` minus its duration and has no end (visits recorded meanwhile go too); a single visit
    /// bounds the listing to its tolerance window.
    public func historyPageFilter(now: Date = Date()) -> [String: Any] {
        let milliseconds = { (date: Date) in (date.timeIntervalSince1970 * 1000).rounded(.down) }
        switch self {
        case .period(let period):
            guard let duration = period.duration else { return ["kind": "all"] }
            return ["kind": "since", "begin": milliseconds(now.addingTimeInterval(-duration))]
        case .interval(let interval):
            return ["kind": "interval", "begin": milliseconds(interval.start), "end": milliseconds(interval.end)]
        case .host(let host):
            return ["kind": "host", "host": host]
        case .url(let url):
            return ["kind": "url", "url": url.absoluteString]
        case .visit(let url, let visitedAt):
            let tolerance = Self.visitTolerance * 1000
            return ["kind": "visit", "url": url.absoluteString, "at": milliseconds(visitedAt),
                    "tolerance": tolerance, "begin": milliseconds(visitedAt) - tolerance]
        }
    }

    /// The host form the shell stores for `.site` (lowercased, without IPv6 brackets).
    static func normalizedHost(_ host: String) -> String {
        let parsed = URL(string: "https://" + host)?.host?.lowercased() ?? host.lowercased()
        return parsed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}

/// Engines that keep their own per-profile history expose its removal. Called after the shell
/// committed the matching deletion; the removal is complete when the call returns.
@MainActor
public protocol BrowserEngineHistoryAccess: AnyObject {
    func removeEngineHistory(_ removal: BrowserEngineHistoryRemoval, profileID: ProfileID) async throws
}

public enum BrowserEngineHistoryError: Error, Equatable { case unavailable, removalIncomplete }
