import Foundation

/// Synthetic-only diagnostics. Call sites do one immutable gate check when disabled.
/// Typed labels exclude destinations, titles and content from the measurement channel.
public enum BrowserPerformance {
    public static let enabled = CommandLine.arguments.contains("--perf-probe")
        && Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true
    public static func isEnabled(synthetic: Bool, arguments: [String]) -> Bool {
        synthetic && arguments.contains("--perf-probe")
    }
    public enum Counter: String, Sendable, CaseIterable {
        case resourceProtected, resourceVisible, resourceFootprintEstimateKB
        case resourceTabs, resourceLive, resourceFrozen, resourceDiscarded, resourceSuspended, resourceUnknown
        case resourceNativeDiscards, resourcePolicyDiscards, resourceRendererProcesses, resourceFootprintBytes
        case resourceLifecycleEvents, resourceMemorySamples, resourcePressureEvents, resourceSweeps, resourceSweepNanoseconds
        case organizationPublications, organizationDeliveries, organizationRefreshes
        case windowProjections, sidebarProjections, sidebarContentPasses, listProjections, sidebarRebuilds, rowsConfigured, glyphDraws, savesScheduled
    }
    public enum Phase: String, Sendable {
        case signatureBegin, signatureReady, menusBegin, menusReady, applicationCreated
        case windowPropertiesReady, nativeWindowReady, layoutBegin, layoutLibraryBegin, layoutLibraryReady, layoutReady
        case sessionAdoptBegin, sessionCaptured, sessionValidated, sessionSurfacesReady, sessionNavigated, sessionRendered
        case nativeBrowserBegin, nativeBrowserReady, windowPlacementReady, windowSessionReady
        case main, admission, authentication, runtime, libraryLoaded, cefInitialize, cefInitialized, cefReady
        case applicationLaunched, environment, sessionRead, sessionDecoded, modelRestored, themesLoaded, environmentCreated
        case settingsLoaded, iconPreload, iconsLoaded, profilesBegin, profilesReady, environmentReady, updaterStarted
        case windowBegin, windowBuilt, windowReady, windowPresented, windowCommitted, windowInteractive
    }
    static let recorder = Recorder()
    public static func count(_ counter: Counter, window: UUID? = nil, amount: Int = 1) {
        guard enabled else { return }
        recorder.count(counter, window: window, amount: amount)
    }
    public static func set(_ counter: Counter, _ value: Int) {
        guard enabled else { return }
        recorder.set(counter, value)
    }
    public static func mark(_ phase: Phase) {
        guard enabled else { return }
        recorder.mark(phase)
    }
    public static func resetCounters() { guard enabled else { return }; recorder.resetCounters() }
    public static var counters: [String: Int] { recorder.counters }
    public static var phases: [String: Double] { recorder.phases }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var windows: Set<UUID> = []
        private var timestamps: [String: Double] = [:]
        func count(_ counter: Counter, window: UUID? = nil, amount: Int = 1) {
            lock.lock(); defer { lock.unlock() }
            counts[counter.rawValue, default: 0] += amount
            if let window { windows.insert(window) }
        }
        func set(_ counter: Counter, _ value: Int) {
            lock.lock(); defer { lock.unlock() }; counts[counter.rawValue] = value
        }
        func mark(_ phase: Phase) {
            lock.lock(); defer { lock.unlock() }
            if timestamps[phase.rawValue] == nil { timestamps[phase.rawValue] = ProcessInfo.processInfo.systemUptime }
        }
        func resetCounters() {
            lock.lock(); defer { lock.unlock() }; counts.removeAll(keepingCapacity: true); windows.removeAll(keepingCapacity: true)
        }
        var counters: [String: Int] {
            lock.lock(); defer { lock.unlock() }
            var result = Dictionary(uniqueKeysWithValues: Counter.allCases.map { ($0.rawValue, counts[$0.rawValue, default: 0]) })
            result["windowsRefreshed"] = windows.count
            return result
        }
        var phases: [String: Double] { lock.lock(); defer { lock.unlock() }; return timestamps }
    }
}
