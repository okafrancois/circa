import BrowserCore
import BrowserEngine
import Darwin
import Foundation
import OSLog

/// Observes resources only. It never admits a discard, freezes a page or changes engine policy.
@MainActor
final class BrowserResourceCoordinator {
    static let shared = BrowserResourceCoordinator()
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
    private var pressure: DispatchSourceMemoryPressure?
    private let memoryReader: (Int32) -> UInt64?
    private let signposter = OSSignposter(subsystem: "local.orbit", category: "resources")
    private var discarding: [ObjectIdentifier: OSSignpostIntervalState] = [:]
    private var waking: [ObjectIdentifier: OSSignpostIntervalState] = [:]
    // Synthetic A/B measurement gate; production always observes.
    var enabled = true

    init(observePressure: Bool = true, memoryReader: @escaping (Int32) -> UInt64? = BrowserResourceCoordinator.footprint) {
        self.memoryReader = memoryReader
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
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled else { return }
        var tab = tabs[identity] ?? Tab(identity: identity, window: window, occurrence: occurrence, profile: profile,
            lifecycle: lifecycle, suspended: suspended, visible: visible, selected: selected ?? visible, backgroundSince: now)
        if visible || tab.visible { tab.backgroundSince = now }
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
