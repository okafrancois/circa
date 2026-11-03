import BrowserCore
import BrowserEngine
import Foundation

/// Window-local, in-memory metadata. Changing profiles or removing a favorite revokes pending reads.
@MainActor
final class BrowserGmailRuntime {
    enum State: Equatable {
        case loading, ready(BrowserGmailInbox), signedOut, unavailable
        var inbox: BrowserGmailInbox? { if case let .ready(value) = self { value } else { nil } }
    }
    private(set) var states: [BrowserGmailAccount: State] = [:]
    var onChange: (() -> Void)?
    var now: () -> Date = Date.init
    private var profile: ProfileID?
    private var accounts: Set<BrowserGmailAccount> = []
    private var tasks: [BrowserGmailAccount: Task<Void, Never>] = [:]
    private var tokens: [BrowserGmailAccount: UUID] = [:]
    private var refreshed: [BrowserGmailAccount: Date] = [:]
    private weak var session: (any BrowserGmailWebSession)?

    func reconcile(profile: ProfileID?, accounts: Set<BrowserGmailAccount>, session: (any BrowserGmailWebSession)?) {
        if self.profile != profile || self.session !== session { clear() }
        self.profile = profile; self.session = session
        for account in self.accounts.subtracting(accounts) { remove(account) }
        self.accounts = accounts
        guard profile != nil, session != nil else { return }
        for account in accounts { refresh(account) }
    }

    func refresh(_ account: BrowserGmailAccount, force: Bool = false) {
        guard accounts.contains(account), let profile, let session, tasks[account] == nil,
              force || refreshed[account].map({ now().timeIntervalSince($0) >= 60 }) != false else { return }
        let token = UUID()
        tokens[account] = token
        if states[account]?.inbox == nil { states[account] = .loading }
        tasks[account] = Task { [weak self] in
            let next: State
            do { next = .ready(try await session.gmailInbox(profileID: profile, account: account)) }
            catch BrowserGmailPreviewError.signedOut { next = .signedOut }
            catch { next = .unavailable }
            guard let self, !Task.isCancelled, self.profile == profile, self.tokens[account] == token,
                  self.accounts.contains(account), self.session === session else { return }
            self.tasks[account] = nil
            self.refreshed[account] = self.now()
            self.states[account] = next
            self.onChange?()
        }
    }

    func invalidate(_ account: BrowserGmailAccount) {
        guard accounts.contains(account) else { return }
        remove(account)
        refresh(account, force: true)
        onChange?()
    }

    func clear() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); tokens.removeAll(); states.removeAll(); refreshed.removeAll(); accounts.removeAll()
        profile = nil; session = nil
    }

    private func remove(_ account: BrowserGmailAccount) {
        tasks.removeValue(forKey: account)?.cancel()
        tokens[account] = nil; states[account] = nil; refreshed[account] = nil
    }
}
