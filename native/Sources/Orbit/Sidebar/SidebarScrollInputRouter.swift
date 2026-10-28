import AppKit

/// Holds the native scroll stream until axis intent is known. In particular, an undecided
/// Began must not start AppKit's native scroll tracker before horizontal arbitration completes.
@MainActor
final class SidebarScrollInputRouter {
    enum Recognition { case inactive, pending, horizontal }
    enum Replay { case unrelated, deliver, recognize, discard }
    private enum Mode { case idle, pending, horizontal, native, discarded }
    private var mode: Mode = .idle
    private var pending: [NSEvent] = []
    private var ownerIsCurrent: (() -> Bool)?
    private var generation = UUID()
    private var discardMomentum = false
    private static var nextNamespace = UInt32.random(in: 1...UInt32.max)
    private let replayNamespace: UInt64
    private var nextReplayID: UInt32 = 0
    private struct ReplayTicket {
        let originalUserData: Int64
        let recognize: Bool
        let isCurrent: () -> Bool
    }
    private var tickets: [UInt64: ReplayTicket] = [:]

    init() {
        replayNamespace = UInt64(Self.nextNamespace) << 32
        Self.nextNamespace &+= 1
        if Self.nextNamespace == 0 { Self.nextNamespace = 1 }
    }

    /// Tests record the lossless native handoff instead of entering AppKit's OS tracking loop.
    var postNativeEvent: (NSEvent) -> Void = { NSApp.postEvent($0, atStart: true) }
    static let maximumPendingEvents = 256

    var hasOwnedSequence: Bool { mode != .idle || discardMomentum }

    func invalidate(preserveRecognition: Bool = false) {
        generation = UUID()
        pending.removeAll()
        ownerIsCurrent = nil
        if mode != .idle { mode = .discarded; discardMomentum = true }
        if preserveRecognition { tickets = tickets.filter { $0.value.recognize } }
        else { tickets.removeAll() }
        // Retired marker values remain in our namespace and are rejected even after the table
        // is cleared. No NSEvent object identity or timestamp uniqueness is assumed.
    }

    func releaseUnownedSequence() {
        invalidate()
        mode = .idle
        discardMomentum = false
    }

    func replay(_ event: NSEvent) -> Replay {
        guard event.type == .scrollWheel, let cg = event.cgEvent else { return .unrelated }
        let marker = UInt64(bitPattern: cg.getIntegerValueField(.eventSourceUserData))
        guard marker & 0xFFFF_FFFF_0000_0000 == replayNamespace else { return .unrelated }
        guard let ticket = tickets.removeValue(forKey: marker) else { return .discard }
        cg.setIntegerValueField(.eventSourceUserData, value: ticket.originalUserData)
        guard ticket.isCurrent() else { return .discard }
        return ticket.recognize ? .recognize : .deliver
    }

    /// Called after window/sidebar hit testing. True means the original event is reserved;
    /// false means normal AppKit dispatch continues. No native scrolling is implemented here.
    func route(_ event: NSEvent, inside: Bool, captureOwner: () -> (() -> Bool)?,
               recognize: () -> Recognition, cancelRecognition: () -> Void) -> Bool {
        let begins = event.phase.contains(.began)
        let mayBegin = event.phase.contains(.mayBegin)
        if begins || mayBegin {
            if mayBegin, mode == .horizontal { return true }
            guard inside, let owner = captureOwner(), owner() else {
                releaseUnownedSequence()
                return false
            }
            // A mayBegin buffered immediately before Began belongs to the same stream.
            let prefix = begins && mode == .pending && pending.allSatisfy({ $0.phase.contains(.mayBegin) }) ? pending : []
            generation = UUID()
            tickets = tickets.filter { $0.value.recognize }
            ownerIsCurrent = owner
            discardMomentum = false
            pending = prefix
            mode = .pending
        }
        if !event.momentumPhase.isEmpty, discardMomentum {
            if event.momentumPhase.contains(.ended) { discardMomentum = false }
            return true
        }
        if mode == .native || mode == .discarded {
            let discard = mode == .discarded || ownerIsCurrent?() != true
            if event.momentumPhase.contains(.ended) || event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                mode = .idle
                ownerIsCurrent = nil
            }
            return discard
        }
        guard mode == .pending else {
            return recognize() == .horizontal
        }
        guard ownerIsCurrent?() == true else {
            cancelRecognition()
            pending.removeAll()
            mode = .discarded
            return true
        }
        pending.append(event)
        if mayBegin { return true }
        let identity = generation
        let recognition = recognize()
        // External cancellation during recognition retires the stream rather than replaying
        // its old input into whatever now occupies the sidebar.
        guard generation == identity else { return true }
        switch recognition {
        case .horizontal:
            pending.removeAll()
            mode = .horizontal
            return true
        case .pending:
            guard pending.count >= Self.maximumPendingEvents else { return true }
            // An indefinitely ambiguous stream falls back losslessly to the native scroller.
            cancelRecognition()
            handoff()
            return true
        case .inactive:
            handoff()
            return true
        }
    }

    private func handoff() {
        guard let owner = ownerIsCurrent, owner() else {
            pending.removeAll(); mode = .discarded; return
        }
        let events = pending
        pending.removeAll()
        mode = .native
        let identity = generation
        enqueue(events, recognize: false, isCurrent: { [weak self] in self?.generation == identity && owner() })
    }

    func replayForRecognition(_ events: [NSEvent], isCurrent: @escaping () -> Bool) -> Bool {
        guard tickets.count + events.count <= 1024 else { return false }
        return enqueue(events, recognize: true, isCurrent: isCurrent)
    }

    /// A fresh physical Began follows any prepended queue records. Remove tickets for tails
    /// already consumed by native tracking, while buffered recognition records keep their tags.
    func retireConsumedRecognition() { tickets = tickets.filter { !$0.value.recognize } }

    @discardableResult
    private func enqueue(_ events: [NSEvent], recognize: Bool, isCurrent: @escaping () -> Bool) -> Bool {
        var marked: [(event: NSEvent, source: CGEventSource)] = []
        for event in events {
            guard let cg = event.cgEvent?.copy(), let source = CGEventSource(stateID: .privateState) else {
                tickets.removeAll(); mode = .discarded; return false
            }
            nextReplayID &+= 1
            guard nextReplayID != 0 else { tickets.removeAll(); mode = .discarded; return false }
            let marker = replayNamespace | UInt64(nextReplayID)
            let originalUserData = cg.getIntegerValueField(.eventSourceUserData)
            source.userData = Int64(bitPattern: marker)
            cg.setSource(source)
            guard let queued = NSEvent(cgEvent: cg), queued.windowNumber == event.windowNumber,
                  queued.locationInWindow == event.locationInWindow, queued.timestamp == event.timestamp,
                  queued.phase == event.phase, queued.momentumPhase == event.momentumPhase,
                  queued.scrollingDeltaX == event.scrollingDeltaX, queued.scrollingDeltaY == event.scrollingDeltaY,
                  queued.modifierFlags == event.modifierFlags,
                  queued.hasPreciseScrollingDeltas == event.hasPreciseScrollingDeltas,
                  queued.isDirectionInvertedFromDevice == event.isDirectionInvertedFromDevice else {
                tickets.removeAll(); mode = .discarded; return false
            }
            tickets[marker] = ReplayTicket(originalUserData: originalUserData, recognize: recognize, isCurrent: isCurrent)
            marked.append((queued, source))
        }
        // A private event-source tag survives AppKit's NSEvent serialization. Producer events
        // remain untouched; the monitor restores user data before ordinary native delivery.
        // Prepending in reverse preserves all phases/deltas/timestamps/window targets, even zero Began.
        // No recursive sendEvent/scrollWheel and no system-wide event posting is used.
        for item in marked.reversed() { postNativeEvent(item.event) }
        return true
    }
}
