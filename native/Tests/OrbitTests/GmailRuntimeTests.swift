import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

@MainActor
private final class GmailSessionFixture: BrowserGmailWebSession {
    struct Request {
        let profile: ProfileID
        let account: BrowserGmailAccount
        let continuation: CheckedContinuation<BrowserGmailInbox, Error>
    }
    var requests: [Request] = []
    func gmailInbox(profileID: ProfileID, account: BrowserGmailAccount) async throws -> BrowserGmailInbox {
        try await withCheckedThrowingContinuation { requests.append(.init(profile: profileID, account: account, continuation: $0)) }
    }
}

@MainActor
struct GmailRuntimeTests {
    private let account = BrowserGmailAccount(url: URL(string: "https://mail.google.com/mail/u/0/")!)!
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test("Inbox reads coalesce and keep known metadata while refreshing")
    func cache() async throws {
        let runtime = BrowserGmailRuntime(), service = GmailSessionFixture(), profile = ProfileID()
        let inbox = BrowserGmailInbox(unreadCount: 0, messages: [])
        runtime.reconcile(profile: profile, accounts: [account], session: service)
        runtime.reconcile(profile: profile, accounts: [account], session: service)
        await settle { service.requests.count == 1 }
        #expect(service.requests.count == 1)
        service.requests[0].continuation.resume(returning: inbox)
        await settle { runtime.states[account]?.inbox != nil }
        runtime.refresh(account, force: true)
        #expect(runtime.states[account]?.inbox == inbox)
        await settle { service.requests.count == 2 }
        service.requests[1].continuation.resume(throwing: BrowserGmailPreviewError.signedOut)
        await settle { runtime.states[account] == .signedOut }
        #expect(runtime.states[account]?.inbox == nil)
        runtime.clear()
    }

    @Test("A late response cannot cross profile changes or restore a removed account")
    func revocation() async throws {
        let runtime = BrowserGmailRuntime(), service = GmailSessionFixture(), first = ProfileID(), second = ProfileID()
        runtime.reconcile(profile: first, accounts: [account], session: service)
        await settle { service.requests.count == 1 }
        runtime.reconcile(profile: second, accounts: [account], session: service)
        await settle { service.requests.count == 2 }
        service.requests[0].continuation.resume(returning: .init(unreadCount: 0, messages: []))
        await settle { false }
        #expect(runtime.states[account] == .loading)
        #expect(service.requests[1].profile == second)
        runtime.reconcile(profile: second, accounts: [], session: service)
        service.requests[1].continuation.resume(returning: .init(unreadCount: 0, messages: []))
        await settle { false }
        #expect(runtime.states.isEmpty)
    }
}
