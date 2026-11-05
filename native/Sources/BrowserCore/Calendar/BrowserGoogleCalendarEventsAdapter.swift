import Foundation

public protocol BrowserCalendarGrantProviding: Sendable {
    func lease(for context: BrowserCalendarAccessContext) async -> BrowserCalendarAccessLease?
}

/// Synchronous so a returned grant or response can be rejected immediately after an async boundary.
public protocol BrowserCalendarContextValidating: Sendable {
    func isCurrent(_ context: BrowserCalendarAccessContext) -> Bool
}

public struct BrowserCalendarHTTPResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    public let finalURL: URL

    public init(statusCode: Int, headers: [String: String] = [:], body: Data, finalURL: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }

    public var description: String { "BrowserCalendarHTTPResponse(status: \(statusCode), bodyBytes: \(body.count))" }
    public var debugDescription: String { description }
}

public protocol BrowserCalendarHTTPTransport: Sendable {
    func send(url: URL, bearerToken: String, maximumResponseBytes: Int) async throws -> BrowserCalendarHTTPResponse
}

public struct BrowserGoogleCalendarEventsRequest: Sendable {
    public let start: Date
    public let end: Date
    public let timeZone: BrowserCalendarTimeZone

    public init?(start: Date, end: Date, timeZone: BrowserCalendarTimeZone) {
        let duration = end.timeIntervalSince(start)
        guard duration > 0, duration <= 31 * 24 * 60 * 60 else { return nil }
        self.start = start
        self.end = end
        self.timeZone = timeZone
    }
}

/// Read-only, primary-calendar list adapter. No calendar-list scope or caller-supplied URL is used.
public struct BrowserGoogleCalendarEventsAdapter: Sendable {
    public static let requiredScope = "https://www.googleapis.com/auth/calendar.events.readonly"
    public static let maximumResponseBytes = 1_048_576
    public static let maximumPages = 4
    public static let pageSize = 50
    public static let maximumEvents = maximumPages * pageSize

    private static let endpointHost = "www.googleapis.com"
    private static let endpointPath = "/calendar/v3/calendars/primary/events"
    private static let fields = "nextPageToken,timeZone,items(id,status,summary,updated,start(date,dateTime,timeZone),end(date,dateTime,timeZone),recurringEventId,originalStartTime(date,dateTime,timeZone),htmlLink,hangoutLink,conferenceData(entryPoints(entryPointType,uri)))"

    private let grantProvider: any BrowserCalendarGrantProviding
    private let contextValidator: any BrowserCalendarContextValidating
    private let transport: any BrowserCalendarHTTPTransport
    private let now: @Sendable () -> Date

    public init(grantProvider: any BrowserCalendarGrantProviding,
                contextValidator: any BrowserCalendarContextValidating,
                transport: any BrowserCalendarHTTPTransport = BrowserCalendarURLSessionTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.grantProvider = grantProvider
        self.contextValidator = contextValidator
        self.transport = transport
        self.now = now
    }

    public func fetch(_ request: BrowserGoogleCalendarEventsRequest,
                      context: BrowserCalendarAccessContext) async throws -> BrowserCalendarEventCollection {
        // This guard intentionally precedes grant lookup: private contexts cause no provider access.
        guard !context.isPrivate else { throw BrowserCalendarDataError.access(.privateContext) }
        guard let expectedAccount = context.expectedAccount else { throw BrowserCalendarDataError.access(.accountNotSelected) }
        guard expectedAccount.profileID == context.profileID else { throw BrowserCalendarDataError.access(.profileMismatch) }
        guard contextValidator.isCurrent(context) else { throw BrowserCalendarDataError.staleContext }
        try checkCancellation()

        let lease = await grantProvider.lease(for: context)
        guard !Task.isCancelled else { throw BrowserCalendarDataError.cancelled }
        guard contextValidator.isCurrent(context) else { throw BrowserCalendarDataError.staleContext }
        guard let lease else { throw BrowserCalendarDataError.access(.grantMissing) }
        try validate(lease, context: context, expectedAccount: expectedAccount)

        var pageToken: String?
        var seenPageTokens = Set<String>()
        var rawEvents: [GoogleEventDTO] = []
        var responseTimeZone = request.timeZone
        for pageIndex in 0..<Self.maximumPages {
            try checkLeaseAndContext(lease, context: context)
            let url = try makeURL(request, pageToken: pageToken)
            let response: BrowserCalendarHTTPResponse
            do {
                response = try await transport.send(url: url, bearerToken: lease.tokenForRequest(),
                                                    maximumResponseBytes: Self.maximumResponseBytes)
            } catch is CancellationError {
                guard contextValidator.isCurrent(context) else { throw BrowserCalendarDataError.staleContext }
                throw BrowserCalendarDataError.cancelled
            } catch let error as BrowserCalendarTransportError {
                guard !Task.isCancelled else { throw BrowserCalendarDataError.cancelled }
                try checkLeaseAndContext(lease, context: context)
                switch error {
                case .responseTooLarge: throw BrowserCalendarDataError.unavailable(.responseTooLarge)
                case .redirectRejected: throw BrowserCalendarDataError.unavailable(.redirectRejected)
                case .cancelled: throw BrowserCalendarDataError.cancelled
                case .failed: throw BrowserCalendarDataError.unavailable(.transport)
                }
            } catch {
                if Task.isCancelled { throw BrowserCalendarDataError.cancelled }
                try checkLeaseAndContext(lease, context: context)
                throw BrowserCalendarDataError.unavailable(.transport)
            }
            guard !Task.isCancelled else { throw BrowserCalendarDataError.cancelled }
            try checkLeaseAndContext(lease, context: context)
            guard response.finalURL.absoluteString == url.absoluteString else {
                throw BrowserCalendarDataError.unavailable(.redirectRejected)
            }
            guard response.body.count <= Self.maximumResponseBytes else {
                throw BrowserCalendarDataError.unavailable(.responseTooLarge)
            }
            try classify(response)
            guard let envelope = try? JSONDecoder().decode(GoogleEventsEnvelope.self, from: response.body) else {
                throw BrowserCalendarDataError.unavailable(.malformedResponse)
            }
            guard envelope.items.count <= Self.pageSize,
                  rawEvents.count + envelope.items.count <= Self.maximumEvents else {
                throw BrowserCalendarDataError.unavailable(.responseTooLarge)
            }
            if let providerZone = envelope.timeZone, BrowserCalendarTimeZone(identifier: providerZone) == nil {
                throw BrowserCalendarDataError.unavailable(.malformedResponse)
            }
            if let providerZone = envelope.timeZone, let validZone = BrowserCalendarTimeZone(identifier: providerZone) {
                responseTimeZone = validZone
            }
            rawEvents.append(contentsOf: envelope.items)
            guard let next = envelope.nextPageToken, !next.isEmpty else { break }
            guard next.utf8.count <= 1_024,
                  next.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  seenPageTokens.insert(next).inserted else {
                throw BrowserCalendarDataError.unavailable(.malformedResponse)
            }
            guard pageIndex < Self.maximumPages - 1 else {
                throw BrowserCalendarDataError.unavailable(.paginationLimit)
            }
            pageToken = next
        }

        try checkLeaseAndContext(lease, context: context)
        let fetchedAt = now()
        let events: [BrowserCalendarEvent]
        do {
            events = try rawEvents.map { try makeEvent($0, account: expectedAccount, responseTimeZone: responseTimeZone, fetchedAt: fetchedAt) }
        } catch {
            throw BrowserCalendarDataError.unavailable(.malformedResponse)
        }
        return BrowserCalendarEventCollection(account: expectedAccount, fetchedAt: fetchedAt, events: events)
    }

    private func validate(_ lease: BrowserCalendarAccessLease, context: BrowserCalendarAccessContext,
                          expectedAccount: BrowserCalendarAccountIdentity) throws {
        guard lease.profileID == context.profileID else { throw BrowserCalendarDataError.access(.profileMismatch) }
        guard lease.account.profileID == context.profileID else { throw BrowserCalendarDataError.access(.profileMismatch) }
        guard lease.account == expectedAccount else { throw BrowserCalendarDataError.access(.accountMismatch) }
        guard lease.revision == context.revision else { throw BrowserCalendarDataError.access(.staleLease) }
        guard !lease.isRevoked else { throw BrowserCalendarDataError.access(.revokedLease) }
        guard lease.scopes.contains(Self.requiredScope) else { throw BrowserCalendarDataError.access(.scopeMissing) }
        guard lease.expiresAt > now() else { throw BrowserCalendarDataError.access(.expiredLease) }
        let token = lease.tokenForRequest()
        guard !token.isEmpty, token.utf8.count <= 8_192,
              token.unicodeScalars.allSatisfy({ (0x21...0x7E).contains(Int($0.value)) }) else {
            throw BrowserCalendarDataError.access(.invalidCredential)
        }
    }

    private func checkLeaseAndContext(_ lease: BrowserCalendarAccessLease,
                                     context: BrowserCalendarAccessContext) throws {
        guard !Task.isCancelled else { throw BrowserCalendarDataError.cancelled }
        guard contextValidator.isCurrent(context) else { throw BrowserCalendarDataError.staleContext }
        guard !lease.isRevoked else { throw BrowserCalendarDataError.access(.revokedLease) }
        guard lease.revision == context.revision else { throw BrowserCalendarDataError.access(.staleLease) }
        guard lease.expiresAt > now() else { throw BrowserCalendarDataError.access(.expiredLease) }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw BrowserCalendarDataError.cancelled }
    }

    private func makeURL(_ request: BrowserGoogleCalendarEventsRequest, pageToken: String?) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.endpointHost
        components.path = Self.endpointPath
        var items = [
            URLQueryItem(name: "fields", value: Self.fields),
            URLQueryItem(name: "maxResults", value: String(Self.pageSize)),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "showDeleted", value: "true"),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "timeMax", value: Self.rfc3339(request.end)),
            URLQueryItem(name: "timeMin", value: Self.rfc3339(request.start)),
            URLQueryItem(name: "timeZone", value: request.timeZone.identifier),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = items
        guard let url = components.url, url.scheme == "https", url.host == Self.endpointHost,
              url.path == Self.endpointPath, url.user == nil, url.password == nil else {
            throw BrowserCalendarDataError.unavailable(.invalidRequest)
        }
        return url
    }

    private func classify(_ response: BrowserCalendarHTTPResponse) throws {
        if (300..<400).contains(response.statusCode) { throw BrowserCalendarDataError.unavailable(.redirectRejected) }
        if response.statusCode == 401 { throw BrowserCalendarDataError.unauthorized }
        if response.statusCode == 429 || (response.statusCode == 403 && isRateLimitBody(response.body)) {
            throw BrowserCalendarDataError.rateLimited(retryAfterSeconds: retryAfter(response.headers["Retry-After"] ?? response.headers["retry-after"]))
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 403 { throw BrowserCalendarDataError.unauthorized }
            throw BrowserCalendarDataError.unavailable(.transport)
        }
    }

    private func isRateLimitBody(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: data) else { return false }
        return envelope.error.errors?.contains(where: { ["rateLimitExceeded", "userRateLimitExceeded"] .contains($0.reason ?? "") }) == true
    }

    private func retryAfter(_ value: String?) -> Int? {
        guard let value, let seconds = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), seconds >= 0 else { return nil }
        return min(seconds, 3_600)
    }

    private func makeEvent(_ dto: GoogleEventDTO, account: BrowserCalendarAccountIdentity,
                           responseTimeZone: BrowserCalendarTimeZone,
                           fetchedAt: Date) throws -> BrowserCalendarEvent {
        guard let eventID = dto.id, BrowserCalendarEventIdentity.validIdentifier(eventID) else { throw EventDecodeError.invalid }
        let status: BrowserCalendarEventStatus
        switch dto.status ?? "confirmed" {
        case "confirmed": status = .confirmed
        case "tentative": status = .tentative
        case "cancelled": status = .cancelled
        default: throw EventDecodeError.invalid
        }
        if let title = dto.summary, title.utf8.count > 4_096 { throw EventDecodeError.invalid }
        let interval: BrowserCalendarEventInterval?
        switch (dto.start, dto.end) {
        case (nil, nil):
            guard status == .cancelled else { throw EventDecodeError.invalid }
            interval = nil
        case let (.some(start), .some(end)):
            interval = try makeInterval(start, end)
        default:
            throw EventDecodeError.invalid
        }
        let sourceZoneString = dto.start?.timeZone ?? dto.end?.timeZone ?? responseTimeZone.identifier
        guard let sourceZone = BrowserCalendarTimeZone(identifier: sourceZoneString) else { throw EventDecodeError.invalid }
        let seriesID: String?
        if let value = dto.recurringEventID {
            guard BrowserCalendarEventIdentity.validIdentifier(value) else { throw EventDecodeError.invalid }
            seriesID = value
        } else { seriesID = nil }
        let originalStart = try dto.originalStartTime.map(makeEventDate)
        let occurrenceKey = originalStart.map(occurrenceKey(for:)) ?? "event:" + eventID
        guard let identity = BrowserCalendarEventIdentity(account: account, eventID: eventID, occurrenceKey: occurrenceKey) else {
            throw EventDecodeError.invalid
        }
        let updatedAt = try dto.updated.map(Self.parseInstant)
        let navigationURL = dto.htmlLink.flatMap(BrowserCalendarHTTPSURL.init)
        let videoURL = dto.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
        let joinURL = videoURL.flatMap(BrowserCalendarHTTPSURL.init) ?? dto.hangoutLink.flatMap(BrowserCalendarHTTPSURL.init)
        return BrowserCalendarEvent(identity: identity, title: dto.summary, status: status, interval: interval,
                                    sourceTimeZone: sourceZone, seriesID: seriesID, originalStart: originalStart,
                                    providerUpdatedAt: updatedAt, fetchedAt: fetchedAt,
                                    navigationURL: navigationURL, joinURL: joinURL)
    }

    private func makeInterval(_ start: GoogleEventDateTime, _ end: GoogleEventDateTime) throws -> BrowserCalendarEventInterval {
        switch (start.date, start.dateTime, end.date, end.dateTime) {
        case let (.some(startDate), nil, .some(endDate), nil):
            guard let start = BrowserCalendarLocalDate(iso8601: startDate),
                  let end = BrowserCalendarLocalDate(iso8601: endDate), start < end else { throw EventDecodeError.invalid }
            return .allDay(start: start, endExclusive: end)
        case let (nil, .some(startTime), nil, .some(endTime)):
            let start = try Self.parseInstant(startTime), end = try Self.parseInstant(endTime)
            guard end > start else { throw EventDecodeError.invalid }
            return .timed(start: start, end: end)
        default:
            throw EventDecodeError.invalid
        }
    }

    private func makeEventDate(_ value: GoogleEventDateTime) throws -> BrowserCalendarEventDate {
        switch (value.date, value.dateTime) {
        case let (.some(date), nil):
            guard let value = BrowserCalendarLocalDate(iso8601: date) else { throw EventDecodeError.invalid }
            return .localDate(value)
        case let (nil, .some(time)):
            return .instant(try Self.parseInstant(time))
        default: throw EventDecodeError.invalid
        }
    }

    private func occurrenceKey(for date: BrowserCalendarEventDate) -> String {
        switch date {
        case .instant(let value): "instant:" + Self.rfc3339(value)
        case .localDate(let value): "date:" + value.iso8601
        }
    }

    private static func parseInstant(_ value: String) throws -> Date {
        guard value.utf8.count <= 64,
              let suffix = value.last,
              suffix == "Z" || suffix == "z" || value.range(of: #"[+-][0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw EventDecodeError.invalid
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) { return date }
        throw EventDecodeError.invalid
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public enum BrowserCalendarTransportError: Error, Sendable {
    case responseTooLarge
    case redirectRejected
    case cancelled
    case failed
}

/// Ephemeral transport with no cookies, cache, or redirect following and a streaming byte cap.
public struct BrowserCalendarURLSessionTransport: BrowserCalendarHTTPTransport {
    public init() {}

    public func send(url: URL, bearerToken: String, maximumResponseBytes: Int) async throws -> BrowserCalendarHTTPResponse {
        guard url.scheme == "https", url.host == "www.googleapis.com",
              url.path == "/calendar/v3/calendars/primary/events", url.user == nil, url.password == nil,
              maximumResponseBytes > 0, bearerToken.unicodeScalars.allSatisfy({ (0x21...0x7E).contains(Int($0.value)) }) else {
            throw BrowserCalendarTransportError.failed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let delegate = CalendarResponseCollector(maximumBytes: maximumResponseBytes)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await delegate.perform(session: session, request: request)
            guard let http = response as? HTTPURLResponse, let finalURL = response.url else {
                throw BrowserCalendarTransportError.failed
            }
            var headers: [String: String] = [:]
            if let retry = http.value(forHTTPHeaderField: "Retry-After") { headers["Retry-After"] = retry }
            return BrowserCalendarHTTPResponse(statusCode: http.statusCode, headers: headers, body: data, finalURL: finalURL)
        } catch let error as BrowserCalendarTransportError { throw error }
        catch is CancellationError { throw BrowserCalendarTransportError.cancelled }
        catch {
            if Task.isCancelled { throw BrowserCalendarTransportError.cancelled }
            throw BrowserCalendarTransportError.failed
        }
    }
}

private final class CalendarResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var data = Data()
    private var failure: BrowserCalendarTransportError?

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func perform(session: URLSession, request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        failure = .redirectRejected
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        if response.expectedContentLength > Int64(maximumBytes) {
            failure = .responseTooLarge
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { dataTask.cancel(); return }
        guard data.count <= maximumBytes - chunk.count else {
            failure = .responseTooLarge
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let failure { continuation.resume(throwing: failure) }
        else if let error { continuation.resume(throwing: error) }
        else if let response { continuation.resume(returning: (data, response)) }
        else { continuation.resume(throwing: BrowserCalendarTransportError.failed) }
    }
}

private enum EventDecodeError: Error { case invalid }

private struct GoogleEventsEnvelope: Decodable {
    let nextPageToken: String?
    let timeZone: String?
    let items: [GoogleEventDTO]
}

private struct GoogleEventDTO: Decodable {
    let id: String?
    let status: String?
    let summary: String?
    let updated: String?
    let start: GoogleEventDateTime?
    let end: GoogleEventDateTime?
    let recurringEventID: String?
    let originalStartTime: GoogleEventDateTime?
    let htmlLink: String?
    let hangoutLink: String?
    let conferenceData: GoogleConferenceData?

    enum CodingKeys: String, CodingKey {
        case id, status, summary, updated, start, end, htmlLink, hangoutLink, conferenceData
        case recurringEventID = "recurringEventId"
        case originalStartTime
    }
}

private struct GoogleEventDateTime: Decodable {
    let date: String?
    let dateTime: String?
    let timeZone: String?
}

private struct GoogleConferenceData: Decodable {
    let entryPoints: [GoogleConferenceEntryPoint]?
}

private struct GoogleConferenceEntryPoint: Decodable {
    let entryPointType: String?
    let uri: String?
}

private struct GoogleErrorEnvelope: Decodable {
    let error: GoogleAPIError
}

private struct GoogleAPIError: Decodable {
    let errors: [GoogleAPIErrorItem]?
}

private struct GoogleAPIErrorItem: Decodable {
    let reason: String?
}
