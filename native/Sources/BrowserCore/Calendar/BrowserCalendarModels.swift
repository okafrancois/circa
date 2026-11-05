import Foundation

/// Provider identity is deliberately separate from the browser profile that owns a grant.
public enum BrowserCalendarProvider: String, Codable, Sendable {
    case google
}

public struct BrowserCalendarAccountIdentity: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let provider: BrowserCalendarProvider
    /// Stable provider subject supplied by an explicit authorization flow; never an email address.
    public let subject: String
    public let profileID: ProfileID

    public init?(provider: BrowserCalendarProvider, subject: String, profileID: ProfileID) {
        guard !subject.isEmpty, !subject.contains("@"), subject.utf8.count <= 256,
              subject == subject.trimmingCharacters(in: .whitespacesAndNewlines),
              subject.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.provider = provider
        self.subject = subject
        self.profileID = profileID
    }

    public var description: String { "BrowserCalendarAccountIdentity(<redacted>)" }
    public var debugDescription: String { description }
}

public struct BrowserCalendarLocalDate: Hashable, Codable, Sendable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(iso8601 value: String) {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ (48...57).contains(bytes[$0]) }),
              let year = Int(String(decoding: bytes[0..<4], as: UTF8.self)),
              let month = Int(String(decoding: bytes[5..<7], as: UTF8.self)),
              let day = Int(String(decoding: bytes[8..<10], as: UTF8.self)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day], from: date)
        guard checked.year == year, checked.month == month, checked.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public var iso8601: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day) }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let date = Self(iso8601: value) else { throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid local calendar date") }
        self = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso8601)
    }
}

public struct BrowserCalendarTimeZone: Hashable, Codable, Sendable {
    public let identifier: String

    public init?(identifier: String) {
        guard identifier.utf8.count <= 128,
              identifier.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              TimeZone(identifier: identifier) != nil else { return nil }
        self.identifier = identifier
    }
}

/// Only absolute HTTPS destinations without embedded user information are representable.
public struct BrowserCalendarHTTPSURL: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: URL

    public init?(_ rawValue: String) {
        guard rawValue.utf8.count <= 4_096,
              rawValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let url = components.url else { return nil }
        value = url
    }

    public var description: String { "BrowserCalendarHTTPSURL(<redacted>)" }
    public var debugDescription: String { description }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid HTTPS URL") }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.absoluteString)
    }
}

public struct BrowserCalendarEventIdentity: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let account: BrowserCalendarAccountIdentity
    public let eventID: String
    /// Provider event ID for singles; the provider original-start value for occurrences.
    public let occurrenceKey: String

    public init?(account: BrowserCalendarAccountIdentity, eventID: String, occurrenceKey: String) {
        guard Self.validIdentifier(eventID), Self.validIdentifier(occurrenceKey) else { return nil }
        self.account = account
        self.eventID = eventID
        self.occurrenceKey = occurrenceKey
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 &&
            value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    public var description: String { "BrowserCalendarEventIdentity(<redacted>)" }
    public var debugDescription: String { description }
}

public enum BrowserCalendarEventStatus: String, Codable, Sendable {
    case confirmed
    case tentative
    case cancelled
}

public enum BrowserCalendarEventDate: Hashable, Codable, Sendable {
    case instant(Date)
    case localDate(BrowserCalendarLocalDate)
}

public enum BrowserCalendarEventInterval: Hashable, Codable, Sendable {
    case timed(start: Date, end: Date)
    /// `endExclusive` follows the provider's local-date convention; it is not a UTC duration.
    case allDay(start: BrowserCalendarLocalDate, endExclusive: BrowserCalendarLocalDate)
}

public struct BrowserCalendarEvent: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let identity: BrowserCalendarEventIdentity
    public let title: String?
    public let status: BrowserCalendarEventStatus
    /// Cancelled tombstones may be sparse and have no interval.
    public let interval: BrowserCalendarEventInterval?
    public let sourceTimeZone: BrowserCalendarTimeZone
    public let seriesID: String?
    public let originalStart: BrowserCalendarEventDate?
    public let providerUpdatedAt: Date?
    public let fetchedAt: Date
    public let navigationURL: BrowserCalendarHTTPSURL?
    public let joinURL: BrowserCalendarHTTPSURL?

    public init(identity: BrowserCalendarEventIdentity, title: String?, status: BrowserCalendarEventStatus,
                interval: BrowserCalendarEventInterval?, sourceTimeZone: BrowserCalendarTimeZone,
                seriesID: String?, originalStart: BrowserCalendarEventDate?, providerUpdatedAt: Date?,
                fetchedAt: Date, navigationURL: BrowserCalendarHTTPSURL?, joinURL: BrowserCalendarHTTPSURL?) {
        self.identity = identity
        self.title = title
        self.status = status
        self.interval = interval
        self.sourceTimeZone = sourceTimeZone
        self.seriesID = seriesID
        self.originalStart = originalStart
        self.providerUpdatedAt = providerUpdatedAt
        self.fetchedAt = fetchedAt
        self.navigationURL = navigationURL
        self.joinURL = joinURL
    }

    public var description: String { "BrowserCalendarEvent(<redacted>)" }
    public var debugDescription: String { description }
}

public struct BrowserCalendarEventCollection: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let account: BrowserCalendarAccountIdentity
    public let fetchedAt: Date
    public let events: [BrowserCalendarEvent]

    public init(account: BrowserCalendarAccountIdentity, fetchedAt: Date, events: [BrowserCalendarEvent]) {
        self.account = account
        self.fetchedAt = fetchedAt
        self.events = events
    }

    public var description: String { "BrowserCalendarEventCollection(eventCount: \(events.count))" }
    public var debugDescription: String { description }
}

/// Deliberate caller context. `revision` must change when profile selection or grant state changes.
public struct BrowserCalendarAccessContext: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let profileID: ProfileID
    public let expectedAccount: BrowserCalendarAccountIdentity?
    public let revision: UInt64
    public let isPrivate: Bool

    public init(profileID: ProfileID, expectedAccount: BrowserCalendarAccountIdentity?, revision: UInt64, isPrivate: Bool) {
        self.profileID = profileID
        self.expectedAccount = expectedAccount
        self.revision = revision
        self.isPrivate = isPrivate
    }

    public var description: String { "BrowserCalendarAccessContext(<redacted>)" }
    public var debugDescription: String { description }
}

/// In-memory lease only. It is intentionally neither Codable nor a persistent credential store.
public struct BrowserCalendarAccessLease: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let profileID: ProfileID
    public let account: BrowserCalendarAccountIdentity
    public let revision: UInt64
    public let scopes: Set<String>
    public let expiresAt: Date
    public let isRevoked: Bool
    private let bearerToken: String

    public init(profileID: ProfileID, account: BrowserCalendarAccountIdentity, revision: UInt64,
                scopes: Set<String>, expiresAt: Date, isRevoked: Bool = false, accessToken: String) {
        self.profileID = profileID
        self.account = account
        self.revision = revision
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.isRevoked = isRevoked
        bearerToken = accessToken
    }

    public var description: String { "BrowserCalendarAccessLease(<redacted>)" }
    public var debugDescription: String { description }

    func tokenForRequest() -> String { bearerToken }
}

public enum BrowserCalendarAccessFailure: Equatable, Sendable {
    case privateContext
    case accountNotSelected
    case grantMissing
    case profileMismatch
    case accountMismatch
    case scopeMissing
    case expiredLease
    case revokedLease
    case staleLease
    case invalidCredential
}

public enum BrowserCalendarUnavailableReason: Equatable, Sendable {
    case transport
    case malformedResponse
    case responseTooLarge
    case redirectRejected
    case paginationLimit
    case invalidRequest
}

public enum BrowserCalendarDataError: Error, Equatable, Sendable {
    case access(BrowserCalendarAccessFailure)
    case unavailable(BrowserCalendarUnavailableReason)
    case unauthorized
    case rateLimited(retryAfterSeconds: Int?)
    case staleContext
    case cancelled
}
