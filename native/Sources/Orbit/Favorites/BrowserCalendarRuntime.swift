import BrowserCore
import BrowserEngine
import Foundation
import Network

/// Memory only. Every publication is fenced by profile, account membership, source and request token.
@MainActor
final class BrowserCalendarRuntime {
    private(set) var agendas: [BrowserCalendarWebAccount: BrowserCalendarWebAgenda] = [:]
    var onChange: (() -> Void)?
    var now: () -> Date = Date.init
    var online = true
    private var profile: ProfileID?
    private var accounts: Set<BrowserCalendarWebAccount> = []
    private var tasks: [BrowserCalendarWebAccount: Task<Void, Never>] = [:]
    private var tokens: [BrowserCalendarWebAccount: UUID] = [:]
    private var nextRead: [BrowserCalendarWebAccount: Date] = [:]
    private var failures: [BrowserCalendarWebAccount: Int] = [:]
    private var stopped: Set<BrowserCalendarWebAccount> = []
    private weak var session: (any BrowserCalendarWebSession)?
    private let network = NWPathMonitor()
    init() {
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.online = path.status == .satisfied }
        }
        network.start(queue: DispatchQueue.global(qos: .utility))
    }
    deinit { network.cancel() }

    func reconcile(profile: ProfileID?, accounts: Set<BrowserCalendarWebAccount>, session: (any BrowserCalendarWebSession)?) {
        if self.profile != profile || self.session !== session { clear() }
        self.profile = profile; self.session = session
        for account in self.accounts.subtracting(accounts) { remove(account) }
        self.accounts = accounts
        for (account, agenda) in agendas where !agenda.isFresh(at: now()) { agendas[account] = nil }
    }
    func refresh(_ account: BrowserCalendarWebAccount) {
        guard online, !stopped.contains(account), accounts.contains(account), let profile, let session,
              tasks[account] == nil, nextRead[account].map({ now() >= $0 }) != false else { return }
        let token = UUID(); tokens[account] = token
        nextRead[account] = now().addingTimeInterval(60 + Double.random(in: 0...5))
        tasks[account] = Task { [weak self] in
            do {
                let agenda = try await session.calendarAgenda(profileID: profile, account: account, day: self?.now() ?? Date(), timeZone: .current)
                guard let self, self.accepts(account, profile, session, token) else { return }
                self.agendas[account] = agenda; self.failures[account] = nil
            } catch {
                guard let self, self.accepts(account, profile, session, token) else { return }
                self.agendas[account] = nil
                let count = min(10, (self.failures[account] ?? 0) + 1); self.failures[account] = count
                var delay = min(3600, 60 * pow(2, Double(count)))
                if case BrowserCalendarWebError.signedOut = error { self.stopped.insert(account) }
                if case let BrowserCalendarWebError.throttled(retry) = error { delay = max(delay, retry) }
                self.nextRead[account] = self.now().addingTimeInterval(delay)
            }
            guard let self, self.accepts(account, profile, session, token) else { return }
            self.tasks[account] = nil; self.onChange?()
        }
    }
    func sessionChanged(_ account: BrowserCalendarWebAccount) {
        tasks.removeValue(forKey: account)?.cancel(); tokens[account] = nil
        agendas[account] = nil; stopped.remove(account)
        // Keep the request budget even when navigation changes the account.
        onChange?()
    }
    func sessionChanged() {
        for account in accounts { sessionChanged(account) }
    }
    func clear() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); tokens.removeAll(); agendas.removeAll(); nextRead.removeAll()
        stopped.removeAll(); failures.removeAll(); accounts.removeAll(); profile = nil; session = nil
    }
    private func remove(_ account: BrowserCalendarWebAccount) {
        tasks.removeValue(forKey: account)?.cancel(); tokens[account] = nil; agendas[account] = nil
        stopped.remove(account)
    }
    private func accepts(_ account: BrowserCalendarWebAccount, _ profile: ProfileID,
                         _ session: any BrowserCalendarWebSession, _ token: UUID) -> Bool {
        !Task.isCancelled && self.profile == profile && self.session === session && tokens[account] == token && accounts.contains(account)
    }
}
