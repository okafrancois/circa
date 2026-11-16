import Foundation

/// Bounded coalescing: metadata cannot postpone a pending structural checkpoint.
/// A structural change after a quiet period is saved after `structuralDelay`; while changes keep
/// arriving, saves are spaced at least `burstInterval` apart, so a burst costs about one save per
/// second instead of one per `structuralDelay`. No change waits longer than `burstInterval` past
/// the previous save (metadata keeps its own longer delay). Quit and power events save at once.
public struct BrowserSessionSaveSchedule: Sendable {
    public static let structuralDelay: TimeInterval = 0.15
    public static let metadataDelay: TimeInterval = 2.5
    public static let burstInterval: TimeInterval = 1

    public private(set) var deadline: TimeInterval?
    public private(set) var lastSave: TimeInterval?
    public init() {}

    @discardableResult
    public mutating func schedule(at now: TimeInterval, metadataOnly: Bool) -> TimeInterval {
        var proposed = now + (metadataOnly ? Self.metadataDelay : Self.structuralDelay)
        if let lastSave { proposed = max(proposed, lastSave + Self.burstInterval) }
        deadline = min(deadline ?? proposed, proposed)
        return max(0, deadline! - now)
    }

    /// Clears the pending deadline without recording a save (cancelled or superseded work).
    public mutating func reset() { deadline = nil }

    /// Clears the pending deadline and records that a save started at `time`.
    public mutating func reset(savedAt time: TimeInterval) {
        deadline = nil
        lastSave = time
    }
}
