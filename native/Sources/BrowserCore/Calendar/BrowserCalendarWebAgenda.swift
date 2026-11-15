import Foundation

/// Ephemeral web-session projection. Deliberately not Codable or part of the saved session.
public struct BrowserCalendarWebAccount: Hashable, Sendable {
    public let slot: Int
    public init?(url: URL) {
        guard url.scheme == "https", url.host == "calendar.google.com", url.user == nil,
              url.password == nil, url.port == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(parts.queryItems ?? []).contains(where: { ["authuser", "src"].contains($0.name) }) else { return nil }
        let path = url.pathComponents
        // A Favorite selects a slot, never an identity. The hidden canonical page still
        // has to verify its signed-in account before and after reading the agenda.
        if path.isEmpty || path == ["/"] || path == ["/", "calendar"] || (path.count >= 3 && path[1] == "calendar" && path[2] == "r") {
            self.slot = 0
        } else {
            guard path.count >= 4, path[1] == "calendar", path[2] == "u",
                  let slot = Int(path[3]), (0...99).contains(slot), String(slot) == path[3] else { return nil }
            self.slot = slot
        }
    }
    public var pageURL: URL { URL(string: "https://calendar.google.com/calendar/u/\(slot)/r")! }
}

public enum BrowserCalendarWebError: Error { case unavailable, invalidResponse, signedOut, throttled(TimeInterval) }

public struct BrowserCalendarWebEvent: Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date?
    public let joinURL: URL?
    public init(id: String, title: String, start: Date, end: Date? = nil, joinURL: URL? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.joinURL = joinURL
    }
}

public struct BrowserCalendarWebAgenda: Equatable, Sendable {
    public let events: [BrowserCalendarWebEvent]
    public let fetchedAt: Date
    public let day: Date
    public let timeZone: TimeZone
    /// Used only to detect session/account replacement; never persisted or displayed.
    public let binding: String
    public init(events: [BrowserCalendarWebEvent], fetchedAt: Date, day: Date, timeZone: TimeZone, binding: String) {
        self.events = events; self.fetchedAt = fetchedAt; self.day = day; self.timeZone = timeZone; self.binding = binding
    }
    public func isFresh(at now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return now >= fetchedAt && now.timeIntervalSince(fetchedAt) < 120 && calendar.isDate(day, inSameDayAs: now)
    }

    public func nextMeeting(at now: Date, reminderTime: BrowserCalendarReminderTime = .fiveMinutes) -> BrowserCalendarWebEvent? {
        guard isFresh(at: now), let interval = reminderTime.interval else { return nil }
        return events.filter { event in
            guard let url = event.joinURL, BrowserCalendarBootstrap.meetingURL(url.absoluteString) == url else { return false }
            return event.start >= now && event.start.timeIntervalSince(now) <= interval
        }.min { $0.start < $1.start }
    }

    public static func decode(html: String, account: BrowserCalendarWebAccount, binding: String,
                              day: Date, timeZone: TimeZone, fetchedAt: Date) throws -> Self {
        guard html.utf8.count <= 1_048_576, !html.localizedCaseInsensitiveContains("<!ENTITY"),
              html.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix("</html>"),
              let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else {
            throw BrowserCalendarWebError.invalidResponse
        }
        func nodes(_ name: String, under node: XMLNode) throws -> [XMLNode] {
            try node.nodes(forXPath: ".//*[contains(concat(' ', normalize-space(@class), ' '), ' \(name) ')]")
        }
        let rows = try nodes("event", under: document)
        let tables = try document.nodes(forXPath: "//table[contains(concat(' ', normalize-space(@class), ' '), ' events ')]")
        if !rows.isEmpty {
            guard tables.count == 1, try nodes("event", under: tables[0]).count == rows.count else {
                throw BrowserCalendarWebError.invalidResponse
            }
        }
        let headings = try nodes("date", under: document)
        let empty = try nodes("message-empty", under: document)
        guard rows.count <= 200, empty.count <= 1, empty.isEmpty || rows.isEmpty else { throw BrowserCalendarWebError.invalidResponse }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone; formatter.dateFormat = "EEE MMM d, yyyy"
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard headings.allSatisfy({ heading in
            guard let text = heading.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let date = formatter.date(from: text) else { return false }
            return calendar.isDate(date, inSameDayAs: day)
        }), (rows.isEmpty ? !empty.isEmpty : headings.count == 1) else { throw BrowserCalendarWebError.invalidResponse }
        var events: [BrowserCalendarWebEvent] = [], ids = Set<String>()
        for row in rows {
            guard let timeCell = try nodes("event-time", under: row).only,
                  let summary = try nodes("event-summary", under: row).only,
                  let link = try nodes("event-link", under: row).only as? XMLElement,
                  let href = link.attribute(forName: "href")?.stringValue,
                  let url = URL(string: href, relativeTo: account.pageURL)?.absoluteURL,
                  url.scheme == "https", url.host == "calendar.google.com", url.port == nil,
                  url.user == nil, url.password == nil, url.path == "/calendar/u/\(account.slot)/event",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let id = components.queryItems?.filter({ $0.name == "eid" }).only?.value,
                  !id.isEmpty, id.count <= 1024, ids.insert(id).inserted,
                  let title = summary.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title.count <= 4096 else { throw BrowserCalendarWebError.invalidResponse }
            let time = (timeCell.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Graphical all-day cells have no text. They are not timed rows.
            if time.isEmpty, !(try timeCell.nodes(forXPath: ".//img")).isEmpty { continue }
            let pattern = #"^(1[0-2]|[1-9])(?::([0-5][0-9]))?(am|pm)$"#
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: time, range: NSRange(time.startIndex..., in: time)) else {
                throw BrowserCalendarWebError.invalidResponse
            }
            func group(_ n: Int) -> String { Range(match.range(at: n), in: time).map { String(time[$0]) } ?? "" }
            let hour = (Int(group(1))! % 12) + (group(3) == "pm" ? 12 : 0)
            let minute = Int(group(2)) ?? 0
            let clockComponents = DateComponents(hour: hour, minute: minute, second: 0)
            let beforeDay = calendar.startOfDay(for: day).addingTimeInterval(-1)
            guard let start = calendar.nextDate(after: beforeDay, matching: clockComponents, matchingPolicy: .strict, repeatedTimePolicy: .first),
                  calendar.isDate(start, inSameDayAs: day),
                  calendar.nextDate(after: beforeDay, matching: clockComponents, matchingPolicy: .strict, repeatedTimePolicy: .last) == start else {
                throw BrowserCalendarWebError.invalidResponse
            }
            events.append(.init(id: id, title: title, start: start))
        }
        return .init(events: events.sorted { $0.start < $1.start }, fetchedAt: fetchedAt,
                     day: calendar.startOfDay(for: day), timeZone: timeZone, binding: binding)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
