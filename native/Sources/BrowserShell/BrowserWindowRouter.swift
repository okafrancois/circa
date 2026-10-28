import Foundation

/// Routes commands to an existing or explicitly requested window, including during startup.
@MainActor
public final class BrowserWindowRouter<Window: AnyObject> {
    public private(set) var windows: [UUID: Window] = [:]
    public private(set) var selectedWindowID: UUID?
    public var onError: ((any Error) -> Void)?

    private let create: @MainActor (UUID) async throws -> Window
    private let present: (Window, Bool) -> Void
    private let dispose: (Window) -> Void
    private var order: [UUID] = []
    private var requestedIDs: Set<UUID> = []
    private var pendingTargetCommands: [UUID: Int] = [:]
    private var pending: Task<Void, Never>?
    private var pendingCommandCount = 0
    private var isClosed = false

    public init(
        create: @escaping @MainActor (UUID) async throws -> Window,
        present: @escaping (Window, Bool) -> Void,
        dispose: @escaping (Window) -> Void
    ) {
        self.create = create
        self.present = present
        self.dispose = dispose
    }

    public var selectedWindow: Window? { selectedWindowID.flatMap { windows[$0] } }
    public var hasPendingWindow: Bool { selectedWindowID != nil && selectedWindow == nil }
    public var hasPendingSelectedWindowCommands: Bool {
        selectedWindowID.map { pendingTargetCommands[$0, default: 0] > 0 } ?? false
    }

    @discardableResult
    public func newWindow(
        id: UUID = UUID(),
        prepare: (@MainActor (Window?) throws -> Void)? = nil
    ) -> UUID? {
        guard !isClosed, requestedIDs.insert(id).inserted else { return nil }
        let sourceID = selectedWindowID
        let sourceWindow = selectedWindow
        selectedWindowID = id
        // A ready source captures its session boundary synchronously. A pending source must first
        // receive all router actions already accepted for it, then prepare before destination creation.
        let deferredPreparation = prepare != nil && sourceID != nil
            && (sourceWindow == nil || sourceID.map { pendingTargetCommands[$0, default: 0] > 0 } == true)
        if deferredPreparation, let sourceID { pendingTargetCommands[sourceID, default: 0] += 1 }
        if !deferredPreparation {
            do { try prepare?(sourceWindow) }
            catch {
                if selectedWindowID == id { selectedWindowID = order.last }
                onError?(error)
                return nil
            }
        }
        guard !isClosed else { return nil }
        enqueue { router in
            do {
                if deferredPreparation {
                    defer { if let sourceID { router.finishTargetCommand(sourceID) } }
                    try prepare?(sourceID.flatMap { router.windows[$0] })
                }
                let window = try await router.create(id)
                guard !router.isClosed else { router.dispose(window); return }
                router.windows[id] = window
                router.order.append(id)
                router.present(window, router.selectedWindowID == id)
            } catch {
                if router.selectedWindowID == id { router.selectedWindowID = router.order.last }
                throw error
            }
        }
        return id
    }

    public func activate(_ id: UUID) {
        guard !isClosed, windows[id] != nil else { return }
        order.removeAll { $0 == id }
        order.append(id)
        selectedWindowID = id
    }

    public func remove(_ id: UUID) {
        windows.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if selectedWindowID == id { selectedWindowID = order.last }
    }

    public func perform(createIfMissing: Bool = false, onAbandon: (() -> Void)? = nil, _ action: @escaping (Window) -> Void) {
        guard !isClosed else { onAbandon?(); return }
        if selectedWindowID == nil, createIfMissing { newWindow() }
        guard let targetID = selectedWindowID else { onAbandon?(); return }
        perform(in: targetID, onAbandon: onAbandon, action)
    }

    /// Preserves the order of physical input from a particular window, including its publication gap.
    public func perform(in targetID: UUID, onAbandon: (() -> Void)? = nil, _ action: @escaping (Window) -> Void) {
        guard !isClosed, requestedIDs.contains(targetID) else { onAbandon?(); return }
        if let window = windows[targetID], pendingTargetCommands[targetID, default: 0] == 0 {
            action(window)
            return
        }
        pendingTargetCommands[targetID, default: 0] += 1
        enqueue(onAbandon: onAbandon) { router in
            defer { router.finishTargetCommand(targetID) }
            // A command captured for a retired or failed window never falls through to a neighbor.
            guard let window = router.windows[targetID] else { onAbandon?(); return }
            action(window)
        }
    }

    public func shutdown() {
        guard !isClosed else { return }
        isClosed = true
        let retired = Array(windows.values)
        windows.removeAll()
        order.removeAll()
        pendingTargetCommands.removeAll()
        selectedWindowID = nil
        onError = nil
        for window in retired { dispose(window) }
    }

    public func waitForPendingCommands() async {
        while pendingCommandCount > 0 { await pending?.value }
    }

    /// Waits for accepted creation and routing work without joining a task that may be waiting
    /// on a stalled source session. Timeout preserves that work for cancellation recovery.
    public func waitForPendingCommands(timeout: Duration?) async -> Bool {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while pendingCommandCount > 0 {
            guard deadline.map({ ContinuousClock.now < $0 }) ?? true, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func finishTargetCommand(_ id: UUID) {
        let count = pendingTargetCommands[id, default: 0]
        if count <= 1 { pendingTargetCommands.removeValue(forKey: id) }
        else { pendingTargetCommands[id] = count - 1 }
    }

    private func enqueue(onAbandon: (() -> Void)? = nil, _ action: @escaping @MainActor (BrowserWindowRouter) async throws -> Void) {
        pendingCommandCount += 1
        let previous = pending
        pending = Task { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            guard !isClosed else { onAbandon?(); return }
            do { try await action(self) }
            catch { if !isClosed { onError?(error) } }
        }
    }
}
