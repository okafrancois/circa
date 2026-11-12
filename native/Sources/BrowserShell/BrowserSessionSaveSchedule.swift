import Foundation

/// Bounded coalescing: metadata cannot postpone a pending structural checkpoint.
public struct BrowserSessionSaveSchedule: Sendable {
    public private(set) var deadline: TimeInterval?
    public init() {}

    @discardableResult
    public mutating func schedule(at now: TimeInterval, metadataOnly: Bool) -> TimeInterval {
        let proposed = now + (metadataOnly ? 2.5 : 0.15)
        deadline = min(deadline ?? proposed, proposed)
        return max(0, deadline! - now)
    }

    public mutating func reset() { deadline = nil }
}
