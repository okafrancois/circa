import Foundation
import Testing
@testable import BrowserCore

struct CalendarBootstrapTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func eid(_ id: String) -> String { Data((id + " opaque-calendar").utf8).base64EncodedString() }
    func agenda(_ ids: [String] = ["one", "series_occurrence", "edited"]) -> BrowserCalendarWebAgenda {
        .init(events: ids.map { .init(id: eid($0), title: "Invented meeting", start: now.addingTimeInterval(120)) },
              fetchedAt: now, day: now, timeZone: .gmt, binding: "fixture@example.invalid")
    }
    func tuple(_ id: String, join: String = "https://meet.google.com/abc-defg-hij") -> [Any] {
        var t = [Any](repeating: NSNull(), count: 83)
        t[0] = id; t[3] = 1; t[4] = 2
        t[35] = [NSNull(), [(now.timeIntervalSince1970 + 120) * 1000]]
        t[36] = [NSNull(), [(now.timeIntervalSince1970 + 2820) * 1000]]
        t[57] = [[[999, join]]]
        return t
    }
    func payload(_ tuples: [[Any]], binding: String = "fixture@example.invalid") throws -> Data {
        var root = [Any](repeating: NSNull(), count: 40)
        root[39] = [NSNull(), [[binding, tuples.map { [NSNull(), NSNull(), NSNull(), $0] }]]]
        return try JSONSerialization.data(withJSONObject: root)
    }
    @Test func exactBindingAndAbsence() throws {
        let a = agenda()
        let result = BrowserCalendarBootstrap.enrich(a, json: try payload([tuple("one"), tuple("series"), tuple("edited"), tuple("deleted")]))
        #expect(result.events.count == 3)
        #expect(result.events[0].end?.timeIntervalSince(result.events[0].start) == 2700)
        #expect(result.events[0].joinURL != nil)
        #expect(result.events[1].end == nil && result.events[1].joinURL == nil)
        #expect(result.events[2].joinURL != nil)
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([])) == a)
    }
    @Test func malformedAndWrongAccountFallBack() throws {
        let a = agenda()
        for data in [Data("not json".utf8), Data(repeating: 32, count: 1_048_577), try payload([tuple("one")], binding: "other@example.invalid"), try payload([tuple("one"), tuple("one")]), try payload([["one"]])] {
            #expect(BrowserCalendarBootstrap.enrich(a, json: data) == a)
        }
        var allDay = tuple("one"); allDay[15] = 1
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([allDay])) == a)
        var invalid = tuple("one"); invalid[36] = [NSNull(), [false]]
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([invalid])) == a)
        #expect(BrowserCalendarBootstrap.occurrenceID("not base64") == nil)
    }
    @Test func strictMeetingDestinations() throws {
        for value in ["https://meet.google.com/abc-defg-hij", "https://us02web.zoom.us/j/12345678901?pwd=invented", "https://teams.microsoft.com/l/meetup-join/19%3ameeting_YWJj%40thread.v2/0?context=%7B%7D"] {
            #expect(BrowserCalendarBootstrap.meetingURL(value) != nil)
        }
        for value in ["http://meet.google.com/abc-defg-hij", "https://user@meet.google.com/abc-defg-hij", "https://meet.google.com:443/abc-defg-hij", "https://meet.google.com.evil.invalid/abc-defg-hij", "https://evilzoom.us/j/123456789", "https://zoom.us/redirect?url=x", "https://meet.google.com/lookup/abc", "https://teams.microsoft.com/l/meetup-join/../evil", "https://meet.google.com/abc-defg-hij#bad", "https://zoom.us/j/123%2f456789", "https://meet.google.com/abc-defg-hij/extra"] {
            #expect(BrowserCalendarBootstrap.meetingURL(value) == nil)
        }
        let result = BrowserCalendarBootstrap.enrich(agenda(), json: try payload([tuple("one", join: "https://example.invalid")]))
        #expect(result.events[0].end != nil && result.events[0].joinURL == nil)
    }
    @Test func reminderTimingAndPreferenceMigration() throws {
        let id = TabID(), now = self.now
        var settings = BrowserProfileSettings()
        #expect(settings.calendarReminderTime(for: id) == .fiveMinutes)
        settings.hiddenCalendarMeetingLinks.insert(id)
        #expect(settings.calendarReminderTime(for: id) == .never)
        settings.hiddenCalendarMeetingLinks.remove(id)
        settings.calendarReminderTimes[id] = .tenMinutes
        let restored = try JSONDecoder().decode(BrowserProfileSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.calendarReminderTime(for: id) == .tenMinutes)
        #expect(try JSONDecoder().decode(BrowserInteractionPreferences.self, from: Data("{}".utf8)).meetingReminderSound)
        for time in BrowserCalendarReminderTime.allCases {
            let boundary = time.interval ?? 120
            let agenda = BrowserCalendarWebAgenda(events: [.init(id: "fixture", title: "Invented", start: now.addingTimeInterval(boundary), joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))], fetchedAt: now, day: now, timeZone: .gmt, binding: "fixture")
            #expect((agenda.nextMeeting(at: now, reminderTime: time) != nil) == (time != .never))
            #expect(agenda.nextMeeting(at: now.addingTimeInterval(-0.01), reminderTime: time) == nil)
            if time == .tenMinutes { #expect(agenda.nextMeeting(at: now, reminderTime: .fiveMinutes) == nil) }
            if time == .fiveMinutes { #expect(agenda.nextMeeting(at: now, reminderTime: .twoMinutes) == nil) }
        }
    }
    @Test func reminderFreshnessAndWindow() throws {
        let a = BrowserCalendarBootstrap.enrich(agenda(), json: try payload([tuple("one")]))
        #expect(a.nextMeeting(at: now) != nil)
        #expect(a.nextMeeting(at: now.addingTimeInterval(120)) == nil)
        #expect(a.nextMeeting(at: now.addingTimeInterval(-1)) == nil)
        let future = BrowserCalendarWebAgenda(events: [.init(id: "later", title: "Later", start: now.addingTimeInterval(301), joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))], fetchedAt: now, day: now, timeZone: .gmt, binding: "fixture")
        #expect(future.nextMeeting(at: now) == nil)
    }
}
