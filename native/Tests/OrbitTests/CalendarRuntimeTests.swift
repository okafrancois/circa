import Foundation
import Testing
import BrowserCore
import BrowserEngine
@testable import Orbit

@MainActor
struct CalendarRuntimeTests {
    let account = BrowserCalendarWebAccount(url: URL(string: "https://calendar.google.com/calendar/u/0/r")!)!
    @MainActor final class Session: BrowserCalendarWebSession {
        var calls = 0
        var error: BrowserCalendarWebError?
        var continuation: CheckedContinuation<BrowserCalendarWebAgenda, any Error>?
        var delay = false
        func calendarAgenda(profileID: ProfileID, account: BrowserCalendarWebAccount, day: Date, timeZone: TimeZone) async throws -> BrowserCalendarWebAgenda {
            calls += 1
            if let error { throw error }
            if delay { return try await withCheckedThrowingContinuation { continuation = $0 } }
            return .init(events: [], fetchedAt: day, day: day, timeZone: timeZone, binding: "invented")
        }
    }
    func settle() async { for _ in 0..<20 { await Task.yield() } }
    @Test func budgetOfflinePrivateAndDisable() async {
        let runtime = BrowserCalendarRuntime(), source = Session(), profile = ProfileID()
        var now = Date(); runtime.now = { now }
        runtime.reconcile(profile: nil, accounts: [], session: nil)
        runtime.refresh(account); await settle(); #expect(source.calls == 0)
        runtime.reconcile(profile: profile, accounts: [account], session: source)
        runtime.online = false; runtime.refresh(account); await settle(); #expect(source.calls == 0)
        runtime.online = true; runtime.refresh(account); await settle(); #expect(source.calls == 1)
        runtime.refresh(account); await settle(); #expect(source.calls == 1)
        now = now.addingTimeInterval(66); runtime.refresh(account); await settle(); #expect(source.calls == 2)
        runtime.reconcile(profile: profile, accounts: [], session: source)
        #expect(runtime.agendas.isEmpty)
        runtime.refresh(account); await settle(); #expect(source.calls == 2)
    }
    @Test func lateResponseCannotCrossProfile() async {
        let runtime = BrowserCalendarRuntime(), source = Session(); source.delay = true
        runtime.reconcile(profile: ProfileID(), accounts: [account], session: source)
        runtime.refresh(account); await settle()
        runtime.reconcile(profile: ProfileID(), accounts: [account], session: source)
        source.continuation?.resume(returning: .init(events: [], fetchedAt: Date(), day: Date(), timeZone: .current, binding: "old"))
        await settle(); #expect(runtime.agendas.isEmpty)
    }
    @Test func authStopsAndThrottleHonorsRetry() async {
        let runtime = BrowserCalendarRuntime(), source = Session()
        var now = Date(); runtime.now = { now }
        runtime.reconcile(profile: ProfileID(), accounts: [account], session: source)
        source.error = .signedOut; runtime.refresh(account); await settle()
        now = now.addingTimeInterval(1000); runtime.refresh(account); await settle(); #expect(source.calls == 1)
        runtime.sessionChanged(account); source.error = .throttled(3600)
        runtime.refresh(account); await settle(); #expect(source.calls == 2)
        now = now.addingTimeInterval(3599); runtime.refresh(account); await settle(); #expect(source.calls == 2)
        now = now.addingTimeInterval(2); runtime.refresh(account); await settle(); #expect(source.calls == 3)
    }
}
