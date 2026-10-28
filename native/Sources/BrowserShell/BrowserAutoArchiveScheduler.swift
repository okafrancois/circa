import BrowserCore
import Foundation

/// Decides when to sweep inactive Today tabs (ORBIT-AUTO-ARCHIVE); thresholds and the clock live in
/// the store. The sleep is injectable so tests advance time without waiting. Windows learn about
/// archived tabs through `BrowserWindowSession.observeOrganizationChanges()`.
@MainActor
public final class BrowserAutoArchiveScheduler {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Tabs the shell protects in addition to every window's visible tab: media, Peek, split panes.
    public var protectedTabs: @MainActor () -> Set<TabID>
    public var onArchive: (@MainActor ([BrowserArchivedTab]) -> Void)?

    private let additionalProtection: @MainActor () async -> Set<TabID>
    private let store: BrowserStore
    private let interval: Duration
    private let sleep: Sleep
    private var loop: Task<Void, Never>?

    /// Reconstruction choice: one sweep per minute bounds lateness to a minute past the threshold.
    public init(
        store: BrowserStore, interval: Duration = .seconds(60),
        protectedTabs: @escaping @MainActor () -> Set<TabID> = { [] },
        additionalProtection: @escaping @MainActor () async -> Set<TabID> = { [] },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.additionalProtection = additionalProtection
        self.store = store
        self.interval = interval
        self.protectedTabs = protectedTabs
        self.sleep = sleep
    }

    public var isRunning: Bool { loop != nil }

    /// Sweeps immediately (launch, wake), then after every interval until `stop()`.
    public func start() {
        guard loop == nil else { return }
        let sleep = self.sleep
        let interval = self.interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.sweep() != nil else { return }
                do { try await sleep(interval) } catch { return }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    @discardableResult
    public func sweep() async -> [BrowserArchivedTab] {
        let additional = await additionalProtection()
        guard !Task.isCancelled else { return [] }
        let archived = await store.archiveExpiredTabs(protecting: protectedTabs().union(additional))
        if !archived.isEmpty { onArchive?(archived) }
        return archived
    }
}
