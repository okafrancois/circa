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
    func attendee(_ address: String, _ status: Any, organizer: Bool = false) -> [Any] {
        var entry = [Any](repeating: NSNull(), count: 15)
        entry[0] = address; entry[5] = status; entry[14] = 1_800_000_000_000
        if organizer { entry[8] = 1; entry[9] = 1 }
        return entry
    }
    func invited(_ id: String, me status: Any, extra: [[Any]] = []) -> [Any] {
        var t = tuple(id)
        t[20] = [attendee("organizer@example.invalid", 3, organizer: true), attendee("fixture@example.invalid", status)] + extra
        return t
    }
    @Test func declinedBySelfIsRemovedEverywhere() throws {
        let a = agenda(["one", "edited"])
        let result = BrowserCalendarBootstrap.enrich(a, json: try payload([invited("one", me: 1), tuple("edited")]))
        #expect(result.events.map(\.id) == [eid("edited")])
        #expect(result.nextMeeting(at: now)?.id == eid("edited"))
        let only = BrowserCalendarBootstrap.enrich(agenda(["one"]), json: try payload([invited("one", me: 1)]))
        #expect(only.events.isEmpty)
        #expect(only.nextMeeting(at: now) == nil)
        for reminder in BrowserCalendarReminderTime.allCases { #expect(only.nextMeeting(at: now, reminderTime: reminder) == nil) }
        var allDay = invited("one", me: 1); allDay[15] = 1
        #expect(BrowserCalendarBootstrap.enrich(agenda(["one"]), json: try payload([allDay])).events.isEmpty)
    }
    @Test func otherResponsesAndOwnEventsUnchanged() throws {
        let a = agenda(["one"])
        let plain = BrowserCalendarBootstrap.enrich(a, json: try payload([tuple("one")]))
        for status in [0, 2, 3] {
            let result = BrowserCalendarBootstrap.enrich(a, json: try payload([invited("one", me: status)]))
            #expect(result == plain)
            #expect(result.nextMeeting(at: now) != nil)
        }
        var own = tuple("one"); own[20] = [attendee("fixture@example.invalid", 3, organizer: true), attendee("guest@example.invalid", 1)]
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([own])) == plain)
        var someoneElse = tuple("one"); someoneElse[20] = [attendee("organizer@example.invalid", 1, organizer: true)]
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([someoneElse])) == plain)
        var upper = tuple("one"); upper[20] = [attendee("FIXTURE@Example.Invalid", 1)]
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([upper])).events.isEmpty)
    }
    @Test func ambiguousOrMalformedResponsesFailOpen() throws {
        let a = agenda(["one"])
        let plain = BrowserCalendarBootstrap.enrich(a, json: try payload([tuple("one")]))
        let values: [Any] = [NSNull(), true, false, "1", "declined", 1.5, -1, 4, [1], ["responseStatus": "declined"]]
        for value in values {
            #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([invited("one", me: value)])) == plain)
        }
        let duplicate = invited("one", me: 1, extra: [attendee("fixture@example.invalid", 3)])
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([duplicate])) == plain)
        for shape: Any in [NSNull(), "fixture@example.invalid", ["fixture@example.invalid", 1], [["fixture@example.invalid"]],
                           [[NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), 1]], [["responseStatus": "declined", "self": true]]] {
            var t = tuple("one"); t[20] = shape
            #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([t])) == plain)
        }
        var huge = tuple("one")
        huge[20] = [attendee("fixture@example.invalid", 1)] + Array(repeating: attendee("guest@example.invalid", 3), count: 5000)
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([huge])) == plain)
        // Unrelated trailing extension data is never read as a response.
        var trailing = tuple("one"); trailing.append(["responseStatus": "declined", "self": true])
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([trailing])) == plain)
    }
    @Test func declineNeedsExactBindingAndAccount() throws {
        let series = agenda(["series_occurrence"])
        #expect(BrowserCalendarBootstrap.enrich(series, json: try payload([invited("series", me: 1)])) == series)
        let a = agenda(["one"])
        var otherAccount = tuple("one"); otherAccount[20] = [attendee("other@example.invalid", 1)]
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([otherAccount], binding: "other@example.invalid")) == a)
        #expect(BrowserCalendarBootstrap.enrich(a, json: try payload([invited("one", me: 1), invited("one", me: 1)])) == a)
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
