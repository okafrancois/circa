import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Darwin

/// Confined live-tab budget diagnostics: memory attribution checkpoints and revisit sessions on
/// loopback fixtures. No OS input is sent; selections use the session API of the owned window.
@MainActor
enum OrbitResourceBudgetProbe {
    static let bundleID = "lab.orbit.orbit.perf-coord-1"
    private static var spaces: [SpaceID] = []
    /// Occurrences per Space, in opening order.
    private static var layout: [[TabOccurrenceID]] = []
    private static var visited = 0
    /// Last requested URL per surface; settling waits for each commit.
    private static var expected: [ObjectIdentifier: URL] = [:]
    private static var offset: TimeInterval = 0
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// Progress to stderr: step names, counts and timings only.
    private static func trace(_ text: String) {
        FileHandle.standardError.write(Data(String(format: "budget-probe %.3f %@\n", uptime, text).utf8))
    }

    static func run(_ owner: OrbitWindowController, store: BrowserStore, root: URL, command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID, Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              let window = owner.window, NSApp.windows.contains(where: { $0 === window }) else { return ["refused": true] }
        let started = uptime
        var result: [String: Any]
        trace("begin \(command["step"] ?? "snapshot")")
        defer { trace("end \(command["step"] ?? "snapshot")") }
        switch command["step"] ?? "snapshot" {
        case "fixture":
            guard let text = command["url"], let base = URL(string: text), base.scheme == "http", base.host == "127.0.0.1" else {
                return ["fixtureRefused": true]
            }
            if command["hide"] != "0" { owner.window?.orderOut(nil) }
            result = await fixture(owner, store: store, base: base, total: Int(command["total"] ?? "") ?? 62)
        case "show":
            await show(owner)
            result = snapshot(owner)
        case "navigate":
            guard let text = command["url"], let base = URL(string: text), base.scheme == "http", base.host == "127.0.0.1" else {
                return ["fixtureRefused": true]
            }
            result = await navigate(owner, base: base, target: Int(command["visits"] ?? "") ?? 200)
        case "dump":
            result = await dump(owner, root: root, label: command["label"] ?? "dump")
        case "policy-suspend":
            let count = await owner.tabSuspension.sweep(now: owner.tabSuspension.clock() + 3601)
            try? await Task.sleep(for: .milliseconds(200))
            result = snapshot(owner); result["sweepDiscards"] = count
        case "close-to-one":
            var tasks: [Task<Bool, Never>] = []
            for occurrences in layout {
                for id in occurrences.dropFirst() {
                    if let surface = owner.session.surface(for: id) { tasks.append(owner.session.closeOwnedSurface(surface)) }
                }
            }
            var closed = 0
            for task in tasks where await task.value { closed += 1 }
            await owner.session.waitForPendingCommands()
            layout = layout.map { Array($0.prefix(1)) }
            result = snapshot(owner); result["closed"] = closed
        case "pressure":
            // Browser-process Chromium pressure plus the shell's own handlers, without stressing the host.
            let surface = owner.session.selectedSurface ?? owner.session.ownedSurfaces.first { !$0.isSuspended }
            let reply = await surface?.devToolsCall("Memory.simulatePressureNotification", params: #"{"level":"critical"}"#)
            BrowserMemoryPressure.simulate()
            owner.resources.coordinator.recordPressure(command["level"] ?? "critical")
            try? await Task.sleep(for: .milliseconds(500))
            result = snapshot(owner); result["chromiumPressureAccepted"] = reply?.0 ?? false
        case "budget-pressure":
            let coordinator = owner.resources.coordinator
            coordinator.recordPressure("warning")
            let count = await owner.tabSuspension.sweep()
            result = snapshot(owner); result["warningDiscards"] = count
            coordinator.recordPressure("normal")
        case "session":
            result = await session(owner, store: store, command: command)
        default:
            result = snapshot(owner)
        }
        result["stepSeconds"] = uptime - started
        result["occlusion"] = OrbitResourcePerformanceProbe.occlusion(owner)
        return result
    }

    /// Hidden windows never deliver renderer frames, so switching away from a loaded tab waits for
    /// paint fallbacks. Checkpoints and sessions therefore run with the window ordered front, inactive.
    private static func show(_ owner: OrbitWindowController) async {
        guard let window = owner.window, !window.isVisible else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func fixture(_ owner: OrbitWindowController, store: BrowserStore, base: URL, total: Int) async -> [String: Any] {
        if spaces.isEmpty {
            for tab in owner.session.snapshot?.tabs ?? [] { owner.session.closeOccurrence(tab.occurrenceID) }
            await owner.session.waitForPendingCommands()
            var profiles: [ProfileID] = []
            for index in 0..<3 { profiles.append(await store.createProfile(name: "Synthetic budget profile \(index)")) }
            for index in 0..<5 {
                guard let space = try? await store.createSpace(name: "Synthetic budget \(index)", profileID: profiles[index % 3]) else {
                    return ["spaceRefused": index]
                }
                spaces.append(space)
            }
            layout = Array(repeating: [], count: spaces.count)
        }
        for (index, space) in spaces.enumerated() {
            let wanted = total / spaces.count + (index < total % spaces.count ? 1 : 0)
            guard layout[index].count < wanted else { continue }
            owner.session.activateSpace(space)
            await owner.session.waitForPendingCommands()
            trace("space \(index) active with \(layout[index].count)")
            while layout[index].count < wanted {
                var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                components.host = "budget-\(index)-\(layout[index].count).localhost"
                let url = components.url!.appendingPathComponent("space-\(index)/tab-\(layout[index].count)")
                owner.session.openTab(url: url)
                await owner.session.waitForPendingCommands()
                guard let id = owner.session.snapshot?.selectedOccurrenceID else { return ["openRefused": true] }
                if let surface = owner.session.surface(for: id) { expected[ObjectIdentifier(surface)] = url }
                layout[index].append(id)
                visited += 1
            }
            trace("space \(index) opened \(layout[index].count)")
        }
        await settle(owner, seconds: 20)
        var result = snapshot(owner)
        result["loadedTabs"] = owner.session.ownedSurfaces.filter { $0.isReady && !$0.navigationState.isLoading }.count
        result["layout"] = layout.map(\.count)
        return result
    }

    /// Further distinct origins in existing tabs, round-robin, so tabs gain history entries.
    private static func navigate(_ owner: OrbitWindowController, base: URL, target: Int) async -> [String: Any] {
        let occurrences = layout.flatMap { $0 }
        guard !occurrences.isEmpty else { return ["noTabs": true] }
        var index = 0
        while visited < target {
            if let surface = owner.session.surface(for: occurrences[index % occurrences.count]), !surface.isSuspended {
                var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                components.host = "visit-\(visited).localhost"
                let url = components.url!.appendingPathComponent("visit-\(visited)")
                surface.navigate(to: url)
                expected[ObjectIdentifier(surface)] = url
                visited += 1
            }
            index += 1
            if index > target * 2 { break }
        }
        await settle(owner, seconds: 20)
        var result = snapshot(owner); result["visited"] = visited
        return result
    }

    private static func settle(_ owner: OrbitWindowController, seconds: TimeInterval) async {
        let deadline = uptime + seconds
        func pending() -> Int {
            owner.session.ownedSurfaces.filter { surface in
                guard !surface.isSuspended else { return false }
                let target = expected[ObjectIdentifier(surface)]
                return !surface.isReady || surface.navigationState.isLoading
                    || (target != nil && surface.navigationState.committedURL != target)
            }.count
        }
        while uptime < deadline, pending() > 0 { try? await Task.sleep(for: .milliseconds(25)) }
        let pending = pending()
        trace("settled pending=\(pending)")
    }

    private static func dump(_ owner: OrbitWindowController, root: URL, label: String) async -> [String: Any] {
        await settle(owner, seconds: 5)
        try? await Task.sleep(for: .milliseconds(1500))
        guard let api = (owner.session.ownedSurfaces.first { !$0.isSuspended } ?? owner.session.selectedSurface)?.pagePerformance else {
            return ["noPerformanceAPI": true]
        }
        let begin = uptime
        let memory = await api.memoryDump()
        let duration = (uptime - begin) * 1000
        let tree = processTree()
        var kinds: [String: [String: Double]] = [:]
        for process in memory.processes {
            let kind = "\(process.kind)"
            kinds[kind, default: [:]]["processes", default: 0] += 1
            kinds[kind, default: [:]]["privateFootprintMiB", default: 0] += Double(process.privateFootprintKB ?? 0) / 1024
            for (name, allocator) in process.allocators {
                kinds[kind, default: [:]][name + "MiB", default: 0] += Double(allocator.metrics["size"] ?? 0) / 1_048_576
            }
        }
        var file: [String: Any] = ["label": label, "status": memory.status.rawValue, "outcome": memory.outcome ?? -1,
            "durationMS": duration, "tree": tree.map { ["pid": $0.pid, "footprint": $0.footprint, "cpuNS": $0.cpu] },
            "snapshot": snapshot(owner)]
        if let data = try? JSONEncoder().encode(memory.processes), let processes = try? JSONSerialization.jsonObject(with: data) {
            file["processes"] = processes
        }
        let url = root.appendingPathComponent("dump-\(label).json")
        if let data = try? JSONSerialization.data(withJSONObject: file, options: [.sortedKeys]) { try? data.write(to: url, options: .atomic) }
        var result = snapshot(owner)
        result["dump"] = ["label": label, "status": memory.status.rawValue, "outcome": memory.outcome ?? -1, "durationMS": duration,
            "kinds": kinds, "file": url.lastPathComponent, "treeFootprintMiB": Double(tree.map(\.footprint).reduce(0, +)) / 1_048_576,
            "treeProcesses": tree.count] as [String: Any]
        return result
    }

    /// Revisits fixture tabs in the given order. Each visit advances the injected policy clock by
    /// `virtualStep` seconds and runs the window's existing sweep once; the 30-second timer is unchanged.
    private static func session(_ owner: OrbitWindowController, store: BrowserStore, command: [String: String]) async -> [String: Any] {
        guard let data = command["plan"]?.data(using: .utf8),
              let plan = try? JSONSerialization.jsonObject(with: data) as? [[Int]] else { return ["planRefused": true] }
        let step = TimeInterval(command["virtualStep"] ?? "") ?? 120
        let coordinator = owner.resources.coordinator
        let maxSeconds = TimeInterval(command["maxSeconds"] ?? "") ?? .infinity
        var truncated = false
        let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime + offset }
        owner.tabSuspension.clock = clock
        coordinator.clock = clock
        if command["show"] == "1" { await show(owner) }
        let occlusion = OrbitResourcePerformanceProbe.occlusion(owner)
        var cpu: [Int32: UInt64] = [:]
        var startCPU: [Int32: UInt64] = [:]
        func sampleCPU() -> UInt64 {
            var footprint: UInt64 = 0
            for process in processTree() {
                if startCPU[process.pid] == nil { startCPU[process.pid] = cpu[process.pid] ?? 0 }
                cpu[process.pid] = process.cpu; footprint += process.footprint
            }
            return footprint
        }
        for process in processTree() { cpu[process.pid] = process.cpu; startCPU[process.pid] = process.cpu }
        var visits: [[String: Any]] = []
        var weightedFootprint = 0.0, weightedLive = 0.0
        let begin = uptime
        for (index, pair) in plan.enumerated() {
            if uptime - begin > maxSeconds { truncated = true; break }
            guard pair.count == 2, layout.indices.contains(pair[0]), layout[pair[0]].indices.contains(pair[1]) else { continue }
            let id = layout[pair[0]][pair[1]]
            let sleeping = Set(owner.session.ownedSurfaces.filter(\.isSuspended).map(ObjectIdentifier.init))
            let target = owner.session.surface(for: id)
            let wasSleeping = target?.isSuspended ?? true
            let start = uptime
            if owner.session.snapshot?.activeSpaceID != spaces[pair[0]] {
                owner.session.activateSpace(spaces[pair[0]])
                await owner.session.waitForPendingCommands()
            }
            owner.session.selectOccurrence(id)
            await owner.session.waitForPendingCommands()
            let cover = owner.tabSuspension.activeCoverIDs.contains(id)
            var latency: Double?
            let deadline = uptime + 8
            while uptime < deadline {
                if let surface = owner.session.surface(for: id), surface.isReady, !surface.isSuspended, !surface.navigationState.isLoading {
                    latency = (uptime - start) * 1000; break
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            let woken = owner.session.ownedSurfaces.filter { sleeping.contains(ObjectIdentifier($0)) && !$0.isSuspended }.count
            offset += step
            let sweepStart = uptime
            let discards = await owner.tabSuspension.sweep()
            let sweepMS = (uptime - sweepStart) * 1000
            let footprint = sampleCPU()
            let live = owner.session.ownedSurfaces.filter { !$0.isSuspended }.count
            weightedFootprint += Double(footprint); weightedLive += Double(live)
            visits.append(["index": index, "space": pair[0], "tab": pair[1], "wasSleeping": wasSleeping, "cover": cover,
                "latencyMS": latency as Any? ?? NSNull(), "woken": woken, "sweepDiscards": discards, "sweepMS": sweepMS,
                "liveSurfaces": live, "treeFootprintBytes": footprint])
        }
        let sessionSeconds = uptime - begin
        _ = sampleCPU()
        let sessionCPU = cpu.reduce(UInt64(0)) { $0 + ($1.value &- (startCPU[$1.key] ?? 0)) }
        try? await Task.sleep(for: .seconds(1))
        let idleStart = processTree(), idleBegin = uptime
        try? await Task.sleep(for: .seconds(2))
        let idleEnd = processTree(), idleSeconds = uptime - idleBegin
        let before = Dictionary(uniqueKeysWithValues: idleStart.map { ($0.pid, $0.cpu) })
        let idleCPU = idleEnd.reduce(UInt64(0)) { $0 + ($1.cpu &- (before[$1.pid] ?? $1.cpu)) }
        var result = snapshot(owner)
        let count = Double(max(visits.count, 1))
        result["session"] = ["visits": visits, "truncated": truncated, "budget": coordinator.budget.map { ["limit": $0.limit, "scope": $0.scope.rawValue,
                "minimumAge": $0.minimumBackgroundAge] as [String: Any] } as Any? ?? NSNull(),
            "stepSeconds": step, "virtualSeconds": offset, "sessionSeconds": sessionSeconds,
            "sessionCPUSeconds": Double(sessionCPU) / 1e9, "idleCPUPercent": 100 * Double(idleCPU) / 1e9 / idleSeconds,
            "finalTreeFootprintBytes": idleEnd.map(\.footprint).reduce(0, +), "finalTreeProcesses": idleEnd.count,
            "meanTreeFootprintBytes": weightedFootprint / count, "meanLiveSurfaces": weightedLive / count,
            "budgetDiscards": coordinator.budgetDiscards, "startOcclusion": occlusion] as [String: Any]
        return result
    }

    struct ProcessSample { let pid: Int32; let footprint: UInt64; let cpu: UInt64 }
    /// This process and its helper children; phys_footprint and CPU nanoseconds, each PID once.
    static func processTree() -> [ProcessSample] {
        let estimate = max(0, Int(proc_listchildpids(getpid(), nil, 0)))
        var children = [Int32](repeating: 0, count: estimate + 128)
        let count = Int(proc_listchildpids(getpid(), &children, Int32(children.count * MemoryLayout<Int32>.size)))
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let pids = Set([getpid()] + children.prefix(max(0, count)).filter { $0 > 0 })
        return pids.sorted().compactMap { pid in
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
            }
            guard status == 0 else { return nil }
            let ticks = usage.ri_user_time + usage.ri_system_time
            return ProcessSample(pid: pid, footprint: usage.ri_phys_footprint,
                cpu: ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1)))
        }
    }

    private static func snapshot(_ owner: OrbitWindowController) -> [String: Any] {
        owner.resources.reconcile()
        let coordinator = owner.resources.coordinator
        coordinator.sampleMemory()
        let surfaces = owner.session.ownedSurfaces
        return ["global": coordinator.summary(), "ownedSurfaces": surfaces.count,
            "suspendedSurfaces": surfaces.filter(\.isSuspended).count, "visited": visited,
            "nativeDiscards": coordinator.nativeDiscards, "policyDiscards": coordinator.policyDiscards,
            "budgetDiscards": coordinator.budgetDiscards, "pressureLevel": coordinator.pressureLevel,
            "coverBytes": owner.tabSuspension.covers.byteCount, "covers": owner.tabSuspension.covers.count,
            "shellFootprintBytes": BrowserResourceCoordinator.footprint(getpid()) ?? 0,
            "budgetLimit": coordinator.budget?.limit ?? 0]
    }
}
