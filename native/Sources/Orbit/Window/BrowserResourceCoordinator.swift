import BrowserCore
import BrowserEngine
import Darwin
import Foundation
import OSLog

/// Optional live-tab budget, off unless the hidden `OrbitLiveTabBudget` default (or the
/// `-OrbitLiveTabBudget N` launch argument) is positive. Memory Saver "Never" also disables it.
struct BrowserLiveTabBudget: Equatable, Sendable {
    enum Scope: String, Sendable { case global, profile }
    /// Live background tabs kept per group; protected tabs count but are never discarded.
    var limit: Int
    var scope: Scope = .global
    /// Tabs shown more recently than this stay live under normal pressure.
    var minimumBackgroundAge: TimeInterval = 300

    static let limitKey = "OrbitLiveTabBudget", scopeKey = "OrbitLiveTabBudgetScope"
    static func configured(_ defaults: UserDefaults = .standard) -> Self? {
        let limit = defaults.integer(forKey: limitKey)
        guard limit > 0 else { return nil }
        return .init(limit: limit, scope: Scope(rawValue: defaults.string(forKey: scopeKey) ?? "") ?? .global)
    }
    /// Warning pressure halves the limit and waives the age; critical keeps no unprotected background tab.
    func effective(pressure: String) -> (limit: Int, minimumAge: TimeInterval) {
        switch pressure {
        case "critical": return (0, 0)
        case "warning": return (limit / 2, 0)
        default: return (limit, minimumBackgroundAge)
        }
    }
}

/// One sweep's budget admissions. Candidates are least recently shown first. A refused candidate
/// admits the next one in its group; candidates owned by another window keep their rank.
struct BrowserLiveTabBudgetPlan {
    struct Entry { let group: ProfileID?; let rank: Int; let position: Int }
    var entries: [ObjectIdentifier: Entry] = [:]
    var excess: [ProfileID?: Int] = [:]
    private var refusals: [ProfileID?: Int] = [:]

    func admits(_ identity: ObjectIdentifier) -> Bool {
        guard let entry = entries[identity] else { return false }
        return entry.rank < excess[entry.group, default: 0] + refusals[entry.group, default: 0]
    }
    mutating func refused(_ identity: ObjectIdentifier) {
        guard admits(identity), let entry = entries[identity] else { return }
        refusals[entry.group, default: 0] += 1
    }
    /// Budget candidates first, oldest first; other surfaces keep their order for the time policy.
    func ordered<Surface: AnyObject>(_ surfaces: [Surface]) -> [Surface] {
        surfaces.filter { entries[ObjectIdentifier($0)] != nil }
            .sorted { entries[ObjectIdentifier($0)]!.position < entries[ObjectIdentifier($1)]!.position }
            + surfaces.filter { entries[ObjectIdentifier($0)] == nil }
    }
}

/// Observes resources. With a configured live-tab budget it also plans discards, which the
/// window's existing suspension sweep admits through its unchanged safety checks.
@MainActor
final class BrowserResourceCoordinator {
    static let shared = BrowserResourceCoordinator(budget: .configured())
    struct Tab {
        let identity: ObjectIdentifier
        var window: UUID
        var occurrence: TabOccurrenceID
        var profile: ProfileID
        var lifecycle: BrowserPageLifecycle?
        var suspended: Bool
        var visible: Bool
        var selected: Bool
        /// Cheap engine admission includes residual shell protections, but is not the async form-value check.
        var engineAllowsSuspension: Bool? = nil
        var backgroundSince: TimeInterval
        /// Last time the tab was selected or in Split in its window; the budget's LRU key.
        var lastShown: TimeInterval
        var lastDiscard: BrowserPageLifecycleChange.Initiator = .none
        var nativeDiscards = 0
        var policyDiscards = 0
        var state: String {
            if suspended { return "suspended" }
            switch lifecycle?.state {
            case .running: return "live"
            case .frozen: return "frozen"
            case .discarded: return "discarded"
            case nil: return "unknown"
            }
        }
        var protected: Bool {
            !sleeping && (selected || engineAllowsSuspension == false || BrowserPageSuspensionPolicy.refusal(lifecycle) != nil)
        }
        var sleeping: Bool { suspended || lifecycle?.state == .discarded }
        func secondsSinceVisible(at now: TimeInterval) -> TimeInterval { visible ? 0 : max(0, now - backgroundSince) }
    }
    struct ProcessMemory {
        let pid: Int32
        /// Nil means inaccessible or exited, not zero footprint.
        let footprint: UInt64?
    }
    private(set) var tabs: [ObjectIdentifier: Tab] = [:]
    private(set) var processes: [ProcessMemory] = []
    private(set) var memorySampleUptime: TimeInterval?
    private(set) var pressureLevel = "normal"
    private(set) var pressureEvents = 0
    private(set) var nativeDiscards = 0
    private(set) var policyDiscards = 0
    private(set) var budgetDiscards = 0
    var budget: BrowserLiveTabBudget?
    /// Injectable monotonic clock, shared with synthetic sessions that advance policy time.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var pressure: DispatchSourceMemoryPressure?
    private let memoryReader: (Int32) -> UInt64?
    private let signposter = OSSignposter(subsystem: "local.orbit", category: "resources")
    private var discarding: [ObjectIdentifier: OSSignpostIntervalState] = [:]
    private var waking: [ObjectIdentifier: OSSignpostIntervalState] = [:]
    // Synthetic A/B measurement gate; production always observes.
    var enabled = true

    init(observePressure: Bool = true, budget: BrowserLiveTabBudget? = nil,
         memoryReader: @escaping (Int32) -> UInt64? = BrowserResourceCoordinator.footprint) {
        self.memoryReader = memoryReader; self.budget = budget
        if observePressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                let event = source?.data ?? []
                Task { @MainActor [weak self] in
                    self?.recordPressure(event.contains(.critical) ? "critical" : event.contains(.warning) ? "warning" : "normal")
                }
            }
            pressure = source
            source.resume()
        }
    }
    deinit { pressure?.cancel() }

    nonisolated static func footprint(_ pid: Int32) -> UInt64? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    func update(identity: ObjectIdentifier, window: UUID, occurrence: TabOccurrenceID, profile: ProfileID,
                lifecycle: BrowserPageLifecycle?, suspended: Bool, visible: Bool, selected: Bool? = nil, engineAllowsSuspension: Bool? = nil,
                now: TimeInterval? = nil) {
        guard enabled else { return }
        let now = now ?? clock()
        var tab = tabs[identity] ?? Tab(identity: identity, window: window, occurrence: occurrence, profile: profile,
            lifecycle: lifecycle, suspended: suspended, visible: visible, selected: selected ?? visible,
            backgroundSince: now, lastShown: now)
        if visible || tab.visible { tab.backgroundSince = now }
        if selected ?? visible || tab.selected { tab.lastShown = now }
        let wasSleeping = tab.sleeping
        tab.window = window; tab.occurrence = occurrence; tab.profile = profile
        tab.lifecycle = lifecycle; tab.suspended = suspended; tab.visible = visible; tab.selected = selected ?? visible
        tab.engineAllowsSuspension = engineAllowsSuspension
        tabs[identity] = tab
        if wasSleeping && !tab.sleeping { beginWake(identity) }
    }

    func change(_ change: BrowserPageLifecycleChange, identity: ObjectIdentifier) {
        guard enabled, var tab = tabs[identity] else { return }
        BrowserPerformance.count(.resourceLifecycleEvents)
        let wasSleeping = tab.sleeping
        if let state = change.state { tab.lifecycle = state }
        if change.event == .aboutToDiscard {
            if discarding[identity] == nil {
                discarding[identity] = signposter.beginInterval("ResourceDiscard", id: signposter.makeSignpostID())
            }
        } else if change.event == .discarded {
            // Count completed native notifications, never inferred state transitions or snapshots.
            tab.lastDiscard = change.initiator
            if change.initiator == .nativePolicy { tab.nativeDiscards += 1; nativeDiscards += 1 }
            if change.initiator == .embedder { tab.policyDiscards += 1; policyDiscards += 1 }
            endDiscard(identity)
        } else if change.event == .closed {
            remove(identity)
            publishCounters()
            return
        } else if discarding[identity] != nil, change.state?.state != .discarded {
            endDiscard(identity)
        }
        tabs[identity] = tab
        if wasSleeping && change.state?.state == .running { beginWake(identity) }
        publishCounters()
    }

    /// Nil when no budget is configured: the sweep then applies only the time policy.
    func budgetPlan(now: TimeInterval) -> BrowserLiveTabBudgetPlan? {
        guard enabled, let budget else { return nil }
        let (limit, minimumAge) = budget.effective(pressure: pressureLevel)
        func group(_ tab: Tab) -> ProfileID? { budget.scope == .profile ? tab.profile : nil }
        let background = tabs.values.filter { !$0.selected && !$0.sleeping }
        var plan = BrowserLiveTabBudgetPlan()
        for tab in background { plan.excess[group(tab), default: -limit] += 1 }
        let candidates = background.filter { !$0.protected && now - $0.lastShown >= minimumAge }.sorted {
            ($0.lastShown, $0.occurrence.rawValue.uuidString) < ($1.lastShown, $1.occurrence.rawValue.uuidString)
        }
        var ranks: [ProfileID?: Int] = [:]
        for (position, tab) in candidates.enumerated() {
            let key = group(tab)
            plan.entries[tab.identity] = .init(group: key, rank: ranks[key, default: 0], position: position)
            ranks[key, default: 0] += 1
        }
        return plan
    }
    func budgetDiscarded() {
        budgetDiscards += 1
        BrowserPerformance.count(.resourceBudgetDiscards)
    }

    func beginWake(_ identity: ObjectIdentifier) {
        guard enabled, waking[identity] == nil else { return }
        waking[identity] = signposter.beginInterval("ResourceWake", id: signposter.makeSignpostID())
    }
    /// Wake endpoint is the shell's settled navigation, not compositor presentation.
    func settled(_ identity: ObjectIdentifier) {
        if let interval = waking.removeValue(forKey: identity) { signposter.endInterval("ResourceWake", interval) }
    }
    private func endDiscard(_ identity: ObjectIdentifier) {
        if let interval = discarding.removeValue(forKey: identity) { signposter.endInterval("ResourceDiscard", interval) }
    }
    private func remove(_ identity: ObjectIdentifier) {
        tabs[identity] = nil
        settled(identity); endDiscard(identity)
    }
    func retain(window: UUID, identities: Set<ObjectIdentifier>) {
        for (id, tab) in tabs where tab.window == window && !identities.contains(id) { remove(id) }
        publishCounters()
    }
    func recordPressure(_ level: String) {
        guard enabled else { return }
        pressureLevel = level; pressureEvents += 1
        BrowserPerformance.count(.resourcePressureEvents)
        sampleMemory()
    }
    func sampleMemory() {
        guard enabled else { return }
        let pids = Set(tabs.values.compactMap { tab -> Int32? in
            guard let state = tab.lifecycle, state.state != .discarded, state.rendererPID > 0 else { return nil }
            return state.rendererPID
        }).union([getpid()])
        processes = pids.sorted().map { ProcessMemory(pid: $0, footprint: memoryReader($0)) }
        memorySampleUptime = ProcessInfo.processInfo.systemUptime
        BrowserPerformance.count(.resourceMemorySamples)
        publishCounters()
    }
    /// Shared renderer charges may appear in multiple window views; only the global view is additive.
    func summary(window: UUID? = nil) -> [String: Int] {
        let values = tabs.values.filter { window == nil || $0.window == window }
        let pids = Set(values.compactMap { tab -> Int32? in
            guard let state = tab.lifecycle, state.state != .discarded, state.rendererPID > 0 else { return nil }
            return state.rendererPID
        })
        return ["tabs": values.count, "live": values.filter { $0.state == "live" }.count,
            "frozen": values.filter { $0.state == "frozen" }.count,
            "discarded": values.filter { $0.lifecycle?.state == .discarded }.count,
            "suspended": values.filter(\.suspended).count, "unknown": values.filter { $0.lifecycle == nil }.count,
            "protected": values.filter(\.protected).count,
            "visible": values.filter(\.visible).count, "rendererProcesses": pids.count,
            "footprintEstimateKB": Int(clamping: values.compactMap { $0.lifecycle?.footprintKB }.reduce(0, +)),
            "rendererFootprintBytes": Int(clamping: processes.filter { pids.contains($0.pid) }.compactMap(\.footprint).reduce(0, +))]
    }
    func publishCounters() {
        guard BrowserPerformance.enabled else { return }
        let values = Array(tabs.values)
        BrowserPerformance.set(.resourceProtected, values.filter(\.protected).count)
        BrowserPerformance.set(.resourceVisible, values.filter(\.visible).count)
        BrowserPerformance.set(.resourceFootprintEstimateKB, Int(clamping: values.compactMap { $0.lifecycle?.footprintKB }.reduce(0, +)))
        BrowserPerformance.set(.resourceTabs, values.count)
        BrowserPerformance.set(.resourceLive, values.filter { $0.state == "live" }.count)
        BrowserPerformance.set(.resourceFrozen, values.filter { $0.state == "frozen" }.count)
        BrowserPerformance.set(.resourceDiscarded, values.filter { $0.lifecycle?.state == .discarded }.count)
        BrowserPerformance.set(.resourceSuspended, values.filter(\.suspended).count)
        BrowserPerformance.set(.resourceUnknown, values.filter { $0.lifecycle == nil }.count)
        BrowserPerformance.set(.resourceNativeDiscards, nativeDiscards)
        BrowserPerformance.set(.resourcePolicyDiscards, policyDiscards)
        BrowserPerformance.set(.resourceRendererProcesses, processes.filter { $0.pid != getpid() }.count)
        BrowserPerformance.set(.resourceFootprintBytes, Int(clamping: processes.compactMap(\.footprint).reduce(0, +)))
    }
}
