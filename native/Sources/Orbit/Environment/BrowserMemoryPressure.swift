import Foundation

/// Each owner keeps its subscription alive and supplies the same handler to deterministic
/// pressure tests. Dispatch delivers only a signal; cache ownership stays on the main actor.
@MainActor
final class BrowserMemoryPressure {
    private static var handlers: [UUID: @MainActor @Sendable () -> Void] = [:]
    private let id = UUID()
    private let source: DispatchSourceMemoryPressure
    init(_ action: @escaping @MainActor @Sendable () -> Void) {
        Self.handlers[id] = action
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { Task { @MainActor in action() } }
        source.resume()
    }
    /// Confined product probes inject the same signal without stressing other applications.
    static func simulate() { for handler in handlers.values { handler() } }
    deinit {
        source.cancel()
        let id = id
        Task { @MainActor in Self.handlers.removeValue(forKey: id) }
    }
}
