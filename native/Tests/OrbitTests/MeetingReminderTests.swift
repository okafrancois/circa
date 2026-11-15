import AppKit
import BrowserCore
import Testing
@testable import Orbit

@MainActor
struct MeetingReminderTests {
    @Test func oneChimeAcrossRefreshesAndWindowsAndNoActiveBanner() async {
        let service = BrowserMeetingReminders(), owner = UUID(), other = UUID(), now = Date()
        var sounds = 0, permissions = 0, posts = 0
        service.playSound = { sounds += 1 }
        service.authorize = { permissions += 1; return true }
        service.post = { _, _, _, _ in posts += 1 }
        service.remove = { _ in }
        let reminder = BrowserMeetingReminders.Reminder(key: "fixture", title: "Invented meeting", start: now.addingTimeInterval(240), sound: true,
            valid: { true }, inactive: { false }, activate: {}, join: { true })
        service.update(owner: owner, reminder: reminder, now: now)
        service.update(owner: other, reminder: reminder, now: now)
        service.update(owner: owner, reminder: nil, now: now)
        service.update(owner: owner, reminder: reminder, now: now)
        for _ in 0..<20 { await Task.yield() }
        #expect(sounds == 1 && permissions == 1 && posts == 0)
    }
    @Test(arguments: [true, false]) func inactiveBannerAndValidatedJoin(soundEnabled: Bool) async throws {
        let service = BrowserMeetingReminders(), owner = UUID(), now = Date()
        var valid = true, inactive = true, activated = 0, joined = 0, removed: [String] = []
        var posted: (String, String, Int)?
        service.playSound = { Issue.record("Background audio must be delivered by the system") }
        service.authorize = { true }
        service.post = { id, title, minutes, sound in
            #expect(sound == soundEnabled); posted = (id, title, minutes)
        }
        service.remove = { removed.append($0) }
        let reminder = BrowserMeetingReminders.Reminder(key: "fixture", title: "Invented meeting", start: now.addingTimeInterval(241), sound: soundEnabled,
            valid: { valid }, inactive: { inactive }, activate: { activated += 1 }, join: { joined += 1; return true })
        service.update(owner: owner, reminder: reminder, now: now)
        for _ in 0..<20 { await Task.yield() }
        let result = try #require(posted)
        #expect(result.1 == "Invented meeting" && result.2 == 5)
        #expect(service.shouldPresent(result.0))
        inactive = false; #expect(!service.shouldPresent(result.0))
        #expect(service.respond(result.0, join: false))
        #expect(activated == 1 && joined == 0 && removed == [result.0])
        // A separate event still reaches its action while the app is already active.
        service.update(owner: owner, reminder: nil, now: now)
        inactive = true
        let next = BrowserMeetingReminders.Reminder(key: "second", title: "Second meeting", start: now.addingTimeInterval(120), sound: soundEnabled,
            valid: { valid }, inactive: { inactive }, activate: { activated += 1 }, join: { joined += 1; return true })
        service.update(owner: owner, reminder: next, now: now)
        for _ in 0..<20 { await Task.yield() }
        let second = try #require(posted?.0)
        #expect(service.respond(second, join: true))
        #expect(joined == 1 && activated == 2)
        valid = false
        #expect(!service.respond(second, join: true))
    }
    @Test func pendingPermissionCannotDeliverAfterSourceRemoval() async throws {
        let service = BrowserMeetingReminders(), owner = UUID(), now = Date()
        var pending: CheckedContinuation<Bool, Never>?
        var posts = 0
        service.authorize = { await withCheckedContinuation { pending = $0 } }
        service.playSound = {}
        service.post = { _, _, _, _ in posts += 1 }
        service.remove = { _ in }
        service.update(owner: owner, reminder: .init(key: "fixture", title: "Invented", start: now.addingTimeInterval(60), sound: true,
            valid: { true }, inactive: { true }, activate: {}, join: { true }), now: now)
        for _ in 0..<20 { await Task.yield() }
        let continuation = try #require(pending)
        service.update(owner: owner, reminder: nil, now: now)
        continuation.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        #expect(posts == 0)
    }
}
