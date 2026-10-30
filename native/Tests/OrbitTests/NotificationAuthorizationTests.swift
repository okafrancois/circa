import Foundation
import Testing
import UserNotifications
@testable import Orbit

@Suite("Main application notification authorization")
@MainActor
struct NotificationAuthorizationTests {
    @Test("Only an undetermined authorization requests OS permission",
          arguments: [UNAuthorizationStatus.notDetermined, .denied, .authorized, .provisional])
    func authorization(status: UNAuthorizationStatus) async {
        var current = status
        var requests = 0
        let authorization = BrowserNotificationAuthorization(status: { current }, request: {
            requests += 1
            current = .authorized
            return true
        })
        #expect(await authorization.authorize() == (status != .denied))
        #expect(requests == (status == .notDetermined ? 1 : 0))
        #expect(await authorization.authorize() == (status != .denied))
        #expect(requests == (status == .notDetermined ? 1 : 0))
    }

    @Test("Denial and request errors keep the settings follow-up available", arguments: [false, true])
    func refusal(throwsError: Bool) async {
        let authorization = BrowserNotificationAuthorization(status: { .notDetermined }, request: {
            if throwsError { throw CocoaError(.userCancelled) }
            return false
        })
        #expect(await authorization.authorize() == false)
    }

    @Test("Concurrent site grants share the pending OS request")
    func concurrentGrants() async throws {
        var current = UNAuthorizationStatus.notDetermined
        var requests = 0
        var response: CheckedContinuation<Bool, Never>?
        let authorization = BrowserNotificationAuthorization(status: { current }, request: {
            requests += 1
            return await withCheckedContinuation { response = $0 }
        })
        let first = Task { await authorization.authorize() }
        for _ in 0..<100 where response == nil { await Task.yield() }
        let completion = try #require(response)
        let second = Task { await authorization.authorize() }
        for _ in 0..<10 { await Task.yield() }
        #expect(requests == 1)
        current = .authorized
        completion.resume(returning: true)
        #expect(await first.value)
        #expect(await second.value)
        #expect(requests == 1)
    }
}
