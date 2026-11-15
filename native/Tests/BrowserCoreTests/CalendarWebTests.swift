import Foundation
import Testing
@testable import BrowserCore

struct CalendarWebTests {
    let account = BrowserCalendarWebAccount(url: URL(string: "https://calendar.google.com/calendar/u/2/r")!)!
    let zone = TimeZone(identifier: "Europe/Paris")!
    var day: Date { ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")! }
    func decode(_ body: String) throws -> BrowserCalendarWebAgenda {
        try .decode(html: "<html><body>" + body + "</body></html>", account: account, binding: "fixture@example.invalid", day: day, timeZone: zone, fetchedAt: day)
    }
    func row(_ time: String = "2:30pm", id: String = "invented", path: String = "/calendar/u/2/event") -> String {
        "<tr class='event'><td class='event-time'>\(time)</td><td class='event-summary'><a class='event-link' href='\(path)?eid=\(id)'>One &amp; Two</a></td></tr>"
    }
    let heading = "<div class='date'>Sun Nov 15, 2026</div>"
    @Test func accountFences() {
        for url in ["http://calendar.google.com/calendar/u/0/r", "https://calendar.google.com.evil.invalid/calendar/u/0/r", "https://calendar.google.com/calendar/u/00/r", "https://calendar.google.com/calendar/u/0/r?authuser=2", "https://user@calendar.google.com/calendar/u/0/r"] {
            #expect(BrowserCalendarWebAccount(url: URL(string: url)!) == nil)
        }
        #expect(account.slot == 2)
    }
    @Test func plainFavoritesUseCanonicalDefaultSlot() throws {
        let canonical = URL(string: "https://calendar.google.com/calendar/u/0/r")!
        for path in ["", "/", "/calendar", "/calendar/", "/calendar/r", "/calendar/r/", "/calendar/r/week/2026/11/15", "/calendar/r?hl=fr#today", "/calendar/u/0", "/calendar/u/0/", "/calendar/u/0/r/day"] {
            let plain = try #require(BrowserCalendarWebAccount(url: URL(string: "https://calendar.google.com" + path)!))
            #expect(plain.slot == 0)
            #expect(plain.pageURL == canonical)
            #expect(plain == BrowserCalendarWebAccount(url: canonical))
        }
    }
    @Test func explicitSlotsArePreservedWithoutRequiringRRoute() throws {
        for slot in [0, 1, 2, 99] {
            for suffix in ["", "/", "/r", "/r/week/2026/11/15", "/event?eid=invented", "/r/settings"] {
                let selected = try #require(BrowserCalendarWebAccount(url: URL(string: "https://calendar.google.com/calendar/u/\(slot)" + suffix)!))
                #expect(selected.slot == slot)
                #expect(selected.pageURL.absoluteString == "https://calendar.google.com/calendar/u/\(slot)/r")
            }
        }
    }
    @Test func ambiguousSelectorsAndMalformedSlotsNeverDefaultToZero() {
        for path in ["/?authuser=1", "/calendar?src=fixture%40example.invalid", "/calendar/r?authuser=", "/calendar/u", "/calendar/u/", "/calendar/u/00", "/calendar/u/-1/r", "/calendar/u/100/r", "/calendar/u/fixture/r", "/calendar/u/1/r?src=primary", "/calendar/u/1/r?authuser=0", "/unrelated", "/calendar/unknown"] {
            #expect(BrowserCalendarWebAccount(url: URL(string: "https://calendar.google.com" + path)!) == nil)
        }
        for origin in ["http://calendar.google.com", "https://calendar.google.com:443", "https://fixture@calendar.google.com", "https://calendar.google.com.example.invalid"] {
            #expect(BrowserCalendarWebAccount(url: URL(string: origin)!) == nil)
        }
    }
    @Test func timedRowsAreStartOnlyAndDecodeEntities() throws {
        let agenda = try decode(heading + "<table class='events'>" + row() + "</table>")
        #expect(agenda.events.count == 1)
        #expect(agenda.events[0].title == "One & Two")
        #expect(agenda.events[0].start == ISO8601DateFormatter().date(from: "2026-11-15T13:30:00Z"))
        #expect(agenda.events[0].end == nil && agenda.events[0].joinURL == nil)
        #expect(agenda.isFresh(at: day.addingTimeInterval(119)))
        #expect(!agenda.isFresh(at: day.addingTimeInterval(120)))
    }
    @Test func onlyRecognizedEmptyIsEmpty() throws {
        #expect(try decode("<div class='message-empty'>No events</div>").events.isEmpty)
        for html in ["", "<script>login()</script>", heading, heading + row("unknown"), heading + row(path: "/calendar/u/0/event"), heading + row() + row(), heading + row() + "<div class='message-empty'></div>", heading.replacingOccurrences(of: "15", with: "16") + row()] {
            #expect(throws: (any Error).self) { try decode(html) }
        }
    }
    @Test func capsTruncationAndExternalEntities() {
        #expect(throws: (any Error).self) { try decode(String(repeating: "x", count: 1_048_577)) }
        #expect(throws: (any Error).self) { try decode("<!ENTITY external SYSTEM 'file:///etc/passwd'>") }
        #expect(throws: (any Error).self) {
            try BrowserCalendarWebAgenda.decode(html: "<html><div class='message-empty'>", account: account, binding: "fixture", day: day, timeZone: zone, fetchedAt: day)
        }
        #expect(throws: (any Error).self) { try decode(heading + (0..<201).map { row(id: "event\($0)") }.joined()) }
    }
    @Test func ambiguousAndMissingWallTimesFailClosed() {
        for (stamp, heading) in [("2026-10-25T12:00:00Z", "Sun Oct 25, 2026"), ("2026-03-29T12:00:00Z", "Sun Mar 29, 2026")] {
            let day = ISO8601DateFormatter().date(from: stamp)!
            let html = "<html><body><div class='date'>" + heading + "</div><table class='events'>" + row("2:30am") + "</table></body></html>"
            #expect(throws: (any Error).self) {
                try BrowserCalendarWebAgenda.decode(html: html, account: account, binding: "invented", day: day, timeZone: zone, fetchedAt: day)
            }
        }
    }
    @Test func allDayIsOmittedAndMarkupIsInert() throws {
        let agenda = try decode(heading + "<table class='events'>" + row("<img alt='' src='https://example.invalid/all-day.png'>") + row("12am", id: "second") + "</table>")
        #expect(agenda.events.count == 1)
        #expect(agenda.events[0].start == ISO8601DateFormatter().date(from: "2026-11-14T23:00:00Z"))
    }
}
