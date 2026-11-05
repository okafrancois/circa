import Foundation
import Testing
@testable import BrowserCore

struct BrowserGoogleCalendarEventsAdapterTests {
    private let syntheticToken = "fixture-access-token-7f31"
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Primary events request is fixed, bounded, read only, and preserves local all day dates")
    func boundedRequestAndAllDay() async throws {
        let fixture = #"{"timeZone":"America/New_York","items":[{"id":"invented-all-day","summary":"Synthetic planning","status":"confirmed","updated":"2026-03-07T19:00:00Z","start":{"date":"2026-03-08"},"end":{"date":"2026-03-09"},"htmlLink":"https://calendar.google.test/event","description":"ignored"}]}"#
        let transport = FixtureTransport([response(fixture)])
        let (adapter, context, account, _) = makeAdapter(transport: transport)
        let result = try await adapter.fetch(request(), context: context)
        let event = try #require(result.events.first)

        #expect(result.account == account)
        #expect(event.status == .confirmed)
        #expect(event.sourceTimeZone.identifier == "America/New_York")
        #expect(event.providerUpdatedAt != nil)
        #expect(event.fetchedAt == now)
        #expect(event.interval == .allDay(start: localDate("2026-03-08"), endExclusive: localDate("2026-03-09")))
        #expect(event.navigationURL?.value.absoluteString == "https://calendar.google.test/event")
        #expect(String(reflecting: event).contains("Synthetic planning") == false)
        #expect(String(reflecting: result).contains("Synthetic planning") == false)

        let requests = await transport.records()
        let sent = try #require(requests.first)
        #expect(sent.url.host == "www.googleapis.com")
        #expect(sent.url.path == "/calendar/v3/calendars/primary/events")
        let query = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: sent.url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        #expect(query["maxResults"] == "50")
        #expect(query["singleEvents"] == "true")
        #expect(query["showDeleted"] == "true")
        #expect(query["orderBy"] == "startTime")
        #expect(query["timeZone"] == "Europe/Paris")
        #expect(query["fields"]?.contains("attendees") == false)
        #expect(query["fields"]?.contains("description") == false)
        #expect(query["fields"]?.contains("conferenceData") == true)
        #expect(query.keys.contains("pageToken") == false)
        #expect(sent.token == syntheticToken)
        let grant = lease(profile: account.profileID, account: account)
        #expect(String(describing: grant).contains("<redacted>"))
        #expect(String(describing: grant).contains(syntheticToken) == false)
        #expect(String(describing: BrowserCalendarDataError.access(.invalidCredential)).contains(syntheticToken) == false)
    }

    @Test("Recurring occurrences retain original start, series, DST offsets, and safe explicit join targets")
    func recurrenceAndJoinURL() async throws {
        let fixture = #"{"timeZone":"America/New_York","items":[{"id":"invented-occurrence","status":"confirmed","summary":"Synthetic recurring event","updated":"2026-03-01T12:00:00Z","start":{"dateTime":"2026-03-08T01:30:00-05:00","timeZone":"America/New_York"},"end":{"dateTime":"2026-03-08T03:30:00-04:00","timeZone":"America/New_York"},"recurringEventId":"invented-series","originalStartTime":{"dateTime":"2026-03-08T01:30:00-05:00","timeZone":"America/New_York"},"conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://meet.google.com/abc-defg-hij"}]}}]}"#
        let transport = FixtureTransport([response(fixture)])
        let (adapter, context, _, _) = makeAdapter(transport: transport)
        let event = try #require(try await adapter.fetch(request(), context: context).events.first)

        #expect(event.seriesID == "invented-series")
        #expect(event.identity.occurrenceKey.hasPrefix("instant:"))
        #expect(event.originalStart != nil)
        #expect(event.joinURL?.value.host == "meet.google.com")
        guard case .timed(let start, let end) = event.interval else { Issue.record("Expected a timed event"); return }
        #expect(end.timeIntervalSince(start) == 3_600)
    }

    @Test("Sparse cancellation is retained without inventing a time or title")
    func sparseCancellation() async throws {
        let fixture = #"{"items":[{"id":"invented-cancelled","status":"cancelled"}]}"#
        let (adapter, context, _, _) = makeAdapter(transport: FixtureTransport([response(fixture)]))
        let event = try #require(try await adapter.fetch(request(), context: context).events.first)
        #expect(event.status == .cancelled)
        #expect(event.interval == nil)
        #expect(event.title == nil)
    }

    @Test("Pagination uses encoded opaque tokens and stops at the fixed page bound")
    func paginationAndBound() async throws {
        let token = "x +&=fixture"
        let transport = FixtureTransport([response(#"{"nextPageToken":"x +&=fixture","items":[{"id":"invented-page-one","start":{"dateTime":"2026-11-05T10:00:00Z"},"end":{"dateTime":"2026-11-05T10:30:00Z"}}]}"#),
                                          response(#"{"items":[{"id":"invented-page-two","start":{"dateTime":"2026-11-05T11:00:00Z"},"end":{"dateTime":"2026-11-05T11:30:00Z"}}]}"#)])
        let (adapter, context, _, _) = makeAdapter(transport: transport)
        let collection = try await adapter.fetch(request(), context: context)
        #expect(collection.events.count == 2)
        let records = await transport.records()
        #expect(records.count == 2)
        let secondQuery = try #require(URLComponents(url: records[1].url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(secondQuery.first(where: { $0.name == "pageToken" })?.value == token)

        let cappedResponses = (0..<BrowserGoogleCalendarEventsAdapter.maximumPages).map { index in
            response(#"{"nextPageToken":"next-\#(index)","items":[]}"#)
        }
        let cappedTransport = FixtureTransport(cappedResponses)
        let (cappedAdapter, cappedContext, _, _) = makeAdapter(transport: cappedTransport)
        await #expect(throws: BrowserCalendarDataError.unavailable(.paginationLimit)) {
            try await cappedAdapter.fetch(request(), context: cappedContext)
        }
        #expect(await cappedTransport.records().count == BrowserGoogleCalendarEventsAdapter.maximumPages)
    }

    @Test("Private, unselected, missing, mismatched, revoked, expired, and under-scoped grants never fetch")
    func grantBoundary() async throws {
        let privateTransport = FixtureTransport([response(#"{"items":[]}"#)])
        let (privateAdapter, privateContext, _, privateGrant) = makeAdapter(transport: privateTransport, isPrivate: true)
        await #expect(throws: BrowserCalendarDataError.access(.privateContext)) {
            try await privateAdapter.fetch(request(), context: privateContext)
        }
        #expect(await privateGrant.calls() == 0)
        #expect(await privateTransport.records().isEmpty)

        let missingAccountContext = BrowserCalendarAccessContext(profileID: profileID(), expectedAccount: nil, revision: 1, isPrivate: false)
        let noAccountGrant = FixtureGrantProvider(nil)
        let noAccountTransport = FixtureTransport([])
        let noAccountAdapter = BrowserGoogleCalendarEventsAdapter(grantProvider: noAccountGrant, contextValidator: FixedValidator(value: true), transport: noAccountTransport, now: { now })
        await #expect(throws: BrowserCalendarDataError.access(.accountNotSelected)) {
            try await noAccountAdapter.fetch(request(), context: missingAccountContext)
        }
        #expect(await noAccountGrant.calls() == 0)

        let selectedProfile = profileID(), selectedAccount = makeAccount(profile: selectedProfile)
        let missingGrant = FixtureGrantProvider(nil)
        let missingTransport = FixtureTransport([])
        let missingAdapter = BrowserGoogleCalendarEventsAdapter(grantProvider: missingGrant, contextValidator: FixedValidator(value: true), transport: missingTransport, now: { now })
        await #expect(throws: BrowserCalendarDataError.access(.grantMissing)) {
            try await missingAdapter.fetch(request(), context: context(profile: selectedProfile, account: selectedAccount))
        }
        #expect(await missingGrant.calls() == 1)
        #expect(await missingTransport.records().isEmpty)

        let wrongProfile = profileID()
        let profile = profileID()
        let account = makeAccount(profile: profile)
        let mismatchLease = lease(profile: wrongProfile, account: account)
        try await assertAccessFailure(.profileMismatch, lease: mismatchLease, expected: account)

        let otherAccount = makeAccount(profile: profile, subject: "invented-other-subject")
        try await assertAccessFailure(.accountMismatch, lease: lease(profile: profile, account: otherAccount), expected: account)
        try await assertAccessFailure(.revokedLease, lease: lease(profile: profile, account: account, revoked: true), expected: account)
        try await assertAccessFailure(.expiredLease, lease: lease(profile: profile, account: account, expiry: now.addingTimeInterval(-1)), expected: account)
        try await assertAccessFailure(.scopeMissing, lease: lease(profile: profile, account: account, scopes: []), expected: account)
        try await assertAccessFailure(.invalidCredential, lease: BrowserCalendarAccessLease(
            profileID: profile, account: account, revision: 1,
            scopes: [BrowserGoogleCalendarEventsAdapter.requiredScope], expiresAt: now.addingTimeInterval(600),
            accessToken: "invalid\r\nfixture"), expected: account)
    }

    @Test("Grant and response awaits revalidate the profile revision, and cancellation rejects returned data")
    func staleAndCancelledWork() async throws {
        let profile = profileID(), account = makeAccount(profile: profile)
        let validator = MutableValidator(true)
        let responseBody = #"{"items":[{"id":"invented-late","start":{"dateTime":"2026-11-05T10:00:00Z"},"end":{"dateTime":"2026-11-05T10:30:00Z"}}]}"#

        let grantValidator = MutableValidator(true)
        let grantTransport = FixtureTransport([response(responseBody)])
        let grantProvider = FixtureGrantProvider(lease(profile: profile, account: account), onLease: { grantValidator.invalidate() })
        let grantAdapter = BrowserGoogleCalendarEventsAdapter(grantProvider: grantProvider, contextValidator: grantValidator,
                                                               transport: grantTransport, now: { now })
        await #expect(throws: BrowserCalendarDataError.staleContext) {
            try await grantAdapter.fetch(request(), context: context(profile: profile, account: account))
        }
        #expect(await grantTransport.records().isEmpty)

        let staleTransport = FixtureTransport([response(responseBody)], onSend: { validator.invalidate() })
        let grant = FixtureGrantProvider(lease(profile: profile, account: account))
        let adapter = BrowserGoogleCalendarEventsAdapter(grantProvider: grant, contextValidator: validator, transport: staleTransport, now: { now })
        await #expect(throws: BrowserCalendarDataError.staleContext) {
            try await adapter.fetch(request(), context: context(profile: profile, account: account))
        }
        #expect(await staleTransport.records().count == 1)

        let cancelTransport = FixtureTransport([response(responseBody)], cancelCurrentTaskOnSend: true)
        let (cancelAdapter, cancelContext, _, _) = makeAdapter(transport: cancelTransport, profile: profile, account: account)
        let cancelledFetch = Task { try await cancelAdapter.fetch(request(), context: cancelContext) }
        await #expect(throws: BrowserCalendarDataError.cancelled) {
            try await cancelledFetch.value
        }
    }

    @Test("HTTP auth, rate limit, unsafe redirects, oversize bodies, and malformed events are typed")
    func typedHTTPFailures() async throws {
        try await assertHTTPFailure(.unauthorized, response: httpResponse(401, #"{"error":{"message":"discarded"}}"#))
        try await assertHTTPFailure(.rateLimited(retryAfterSeconds: 3_600), response: httpResponse(429, "{}", headers: ["Retry-After": "99999"]))
        try await assertHTTPFailure(.rateLimited(retryAfterSeconds: nil), response: httpResponse(403, #"{"error":{"errors":[{"reason":"rateLimitExceeded"}]}}"#))
        try await assertHTTPFailure(.unavailable(.redirectRejected), response: httpResponse(302, "{}"))
        try await assertHTTPFailure(.unavailable(.redirectRejected), response: response("{}", finalURL: URL(string: "https://attacker.invalid/events")!))
        try await assertHTTPFailure(.unavailable(.malformedResponse), response: response("{"))

        let huge = String(repeating: "x", count: BrowserGoogleCalendarEventsAdapter.maximumResponseBytes + 1)
        try await assertHTTPFailure(.unavailable(.responseTooLarge), response: response(huge))
        try await assertHTTPFailure(.unavailable(.malformedResponse), response: response(#"{"items":[{"id":"bad","status":"confirmed","start":{"date":"2026-03-08"},"end":{"date":"2026-03-08"}}]}"#))
    }

    @Test("Credential leases and unsafe event destinations have redacted or rejecting representations")
    func credentialAndURLBoundaries() throws {
        let profile = profileID(), account = makeAccount(profile: profile)
        let grant = lease(profile: profile, account: account)
        #expect(String(describing: grant).contains(syntheticToken) == false)
        #expect(String(reflecting: grant).contains(syntheticToken) == false)
        #expect(BrowserCalendarHTTPSURL("http://meet.google.com/abc") == nil)
        #expect(BrowserCalendarHTTPSURL("https://user:pass@meet.google.com/abc") == nil)
        #expect(BrowserCalendarHTTPSURL("javascript:alert(1)") == nil)
        #expect(BrowserCalendarHTTPSURL("https://meet.google.com/abc")?.value.scheme == "https")
        #expect(BrowserCalendarLocalDate(iso8601: "2026-02-30") == nil)
        #expect(BrowserCalendarAccountIdentity(provider: .google, subject: "owner@example.test", profileID: profile) == nil)
        let response = httpResponse(200, "Synthetic private payload")
        #expect(String(reflecting: response).contains("Synthetic private payload") == false)
        #expect(BrowserGoogleCalendarEventsRequest(start: now, end: now.addingTimeInterval(32 * 86_400), timeZone: zone("UTC")) == nil)
    }

    private func assertAccessFailure(_ failure: BrowserCalendarAccessFailure,
                                     lease: BrowserCalendarAccessLease,
                                     expected: BrowserCalendarAccountIdentity) async throws {
        let transport = FixtureTransport([])
        let provider = FixtureGrantProvider(lease)
        let adapter = BrowserGoogleCalendarEventsAdapter(grantProvider: provider, contextValidator: FixedValidator(value: true), transport: transport, now: { now })
        await #expect(throws: BrowserCalendarDataError.access(failure)) {
            try await adapter.fetch(request(), context: context(profile: expected.profileID, account: expected))
        }
        #expect(await transport.records().isEmpty)
    }

    private func assertHTTPFailure(_ expected: BrowserCalendarDataError,
                                   response: BrowserCalendarHTTPResponse) async throws {
        let transport = FixtureTransport([response])
        let (adapter, context, _, _) = makeAdapter(transport: transport)
        await #expect(throws: expected) { try await adapter.fetch(request(), context: context) }
    }

    private func makeAdapter(transport: FixtureTransport, profile requestedProfile: ProfileID? = nil,
                             account: BrowserCalendarAccountIdentity? = nil, isPrivate: Bool = false) ->
        (BrowserGoogleCalendarEventsAdapter, BrowserCalendarAccessContext, BrowserCalendarAccountIdentity, FixtureGrantProvider) {
        let profile = requestedProfile ?? ProfileID()
        let selected = account ?? makeAccount(profile: profile)
        let context = context(profile: profile, account: selected, isPrivate: isPrivate)
        let provider = FixtureGrantProvider(lease(profile: profile, account: selected))
        let adapter = BrowserGoogleCalendarEventsAdapter(grantProvider: provider, contextValidator: FixedValidator(value: true), transport: transport, now: { now })
        return (adapter, context, selected, provider)
    }

    private func context(profile: ProfileID, account: BrowserCalendarAccountIdentity?, revision: UInt64 = 1,
                         isPrivate: Bool = false) -> BrowserCalendarAccessContext {
        BrowserCalendarAccessContext(profileID: profile, expectedAccount: account, revision: revision, isPrivate: isPrivate)
    }

    private func profileID() -> ProfileID { ProfileID() }

    private func makeAccount(profile: ProfileID, subject: String = "invented-subject-001") -> BrowserCalendarAccountIdentity {
        BrowserCalendarAccountIdentity(provider: .google, subject: subject, profileID: profile)!
    }

    private func lease(profile: ProfileID, account: BrowserCalendarAccountIdentity, revoked: Bool = false,
                       expiry: Date? = nil, scopes: Set<String> = [BrowserGoogleCalendarEventsAdapter.requiredScope],
                       revision: UInt64 = 1) -> BrowserCalendarAccessLease {
        BrowserCalendarAccessLease(profileID: profile, account: account, revision: revision, scopes: scopes,
                                   expiresAt: expiry ?? now.addingTimeInterval(600), isRevoked: revoked,
                                   accessToken: syntheticToken)
    }

    private func request() -> BrowserGoogleCalendarEventsRequest {
        BrowserGoogleCalendarEventsRequest(start: now, end: now.addingTimeInterval(86_400), timeZone: zone("Europe/Paris"))!
    }

    private func zone(_ identifier: String) -> BrowserCalendarTimeZone { BrowserCalendarTimeZone(identifier: identifier)! }
    private func localDate(_ value: String) -> BrowserCalendarLocalDate { BrowserCalendarLocalDate(iso8601: value)! }

    private func response(_ body: String, finalURL: URL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!) -> BrowserCalendarHTTPResponse {
        BrowserCalendarHTTPResponse(statusCode: 200, body: Data(body.utf8), finalURL: finalURL)
    }

    private func httpResponse(_ code: Int, _ body: String, headers: [String: String] = [:]) -> BrowserCalendarHTTPResponse {
        BrowserCalendarHTTPResponse(statusCode: code, headers: headers, body: Data(body.utf8),
                                    finalURL: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!)
    }

}

private struct RecordedCalendarRequest: Sendable {
    let url: URL
    let token: String
}

private actor FixtureTransport: BrowserCalendarHTTPTransport {
    private var responses: [BrowserCalendarHTTPResponse]
    private var sent: [RecordedCalendarRequest] = []
    private let onSend: (@Sendable () -> Void)?
    private let cancelCurrentTaskOnSend: Bool

    init(_ responses: [BrowserCalendarHTTPResponse], onSend: (@Sendable () -> Void)? = nil,
         cancelCurrentTaskOnSend: Bool = false) {
        self.responses = responses
        self.onSend = onSend
        self.cancelCurrentTaskOnSend = cancelCurrentTaskOnSend
    }

    func send(url: URL, bearerToken: String, maximumResponseBytes: Int) async throws -> BrowserCalendarHTTPResponse {
        sent.append(RecordedCalendarRequest(url: url, token: bearerToken))
        onSend?()
        if cancelCurrentTaskOnSend { withUnsafeCurrentTask { $0?.cancel() } }
        guard !responses.isEmpty else { throw BrowserCalendarTransportError.failed }
        let response = responses.removeFirst()
        let baseURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        if response.finalURL == baseURL {
            return BrowserCalendarHTTPResponse(statusCode: response.statusCode, headers: response.headers,
                                               body: response.body, finalURL: url)
        }
        return response
    }

    func records() -> [RecordedCalendarRequest] { sent }
}

private actor FixtureGrantProvider: BrowserCalendarGrantProviding {
    private let value: BrowserCalendarAccessLease?
    private let onLease: (@Sendable () -> Void)?
    private var callCount = 0
    init(_ value: BrowserCalendarAccessLease?, onLease: (@Sendable () -> Void)? = nil) {
        self.value = value
        self.onLease = onLease
    }
    func lease(for context: BrowserCalendarAccessContext) async -> BrowserCalendarAccessLease? {
        callCount += 1
        onLease?()
        _ = context
        return value
    }
    func calls() -> Int { callCount }
}

private struct FixedValidator: BrowserCalendarContextValidating {
    let value: Bool
    func isCurrent(_ context: BrowserCalendarAccessContext) -> Bool { _ = context; return value }
}

private final class MutableValidator: BrowserCalendarContextValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func invalidate() { lock.lock(); value = false; lock.unlock() }
    func isCurrent(_ context: BrowserCalendarAccessContext) -> Bool {
        _ = context
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
