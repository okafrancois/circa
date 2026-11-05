import AppKit
import BrowserEngine
import ChromiumEngine
import Darwin

/// Runtime checks for the additive v17 engine surface in a confined synthetic bundle.
@MainActor
enum OrbitEngineR17Probe {
    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.engine-r17",
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              let window = owner.window, NSApp.windows.contains(where: { $0 === window }) else { return false }
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }

    static func run(_ owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        guard owns(owner), let text = command["url"], let url = URL(string: text),
              url.scheme == "http", url.host == "127.0.0.1",
              let ports = command["ports"]?.split(separator: ",").compactMap({ Int($0) }), ports.count == 7 else {
            return ["ownershipOrFixtureRefused": true]
        }
        guard let anchor = owner.session.selectedSurface,
              let anchorOccurrence = owner.session.snapshot?.selectedOccurrenceID,
              let anchorLifecycle = anchor.pagePerformance else { return ["missingAnchor": true] }
        let existingOccurrences = Set((owner.session.snapshot?.tabs ?? []).map(\.occurrenceID))
        owner.session.openTab(url: url, activate: false)
        await owner.session.waitForQueuedCommands()
        await owner.session.waitForPendingCommands()
        guard let occurrence = owner.session.snapshot?.tabs.first(where: { !existingOccurrences.contains($0.occurrenceID) })?.occurrenceID else {
            return ["missingBackgroundOccurrence": true]
        }
        var tab: ChromiumSurface?
        for _ in 0..<160 {
            if let surface = owner.session.surface(for: occurrence) {
                tab = surface
                if surface.isReady && !surface.navigationState.isLoading { break }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard let tab, let lifecycle = tab.pagePerformance else { return ["missingBackgroundSurface": true] }

        var result: [String: Any] = [:]
        let visibleMask = anchorLifecycle.lifecycle()?.cannotFreezeMask ?? 0
        result["visibleVetoBit"] = visibleMask & (1 << 0) != 0
        let initialVote = owner.engine.freezeTab(tab, frozen: true)
        let removeVote = owner.engine.freezeTab(tab, frozen: false)
        let readdVote = owner.engine.freezeTab(tab, frozen: true)
        result["freezeAddRemoveReadd"] = initialVote && removeVote && readdVote

        _ = await OrbitPerformanceProbe.evaluate(tab,
            "navigator.locks.request('orbit-r17-freeze-smoke',()=>new Promise(r=>globalThis.releaseOrbitR17Lock=r));({started:true})")
        try? await Task.sleep(for: .milliseconds(250))
        let webLockMask = lifecycle.lifecycle()?.cannotFreezeMask ?? 0
        result["webLockVetoBit"] = webLockMask & (1 << 5) != 0
        _ = await OrbitPerformanceProbe.evaluate(tab, "globalThis.releaseOrbitR17Lock?.();({released:true})")

        _ = await OrbitPerformanceProbe.evaluate(anchor,
            "(()=>{let c=new AudioContext(),o=c.createOscillator(),g=c.createGain();g.gain.value=.03;o.connect(g);g.connect(c.destination);o.start();globalThis.orbitR17Audio={c,o};return {started:true}})()")
        try? await Task.sleep(for: .milliseconds(350))
        let audibleMask = anchorLifecycle.lifecycle()?.cannotFreezeMask ?? 0
        result["audibleVetoBit"] = audibleMask & (1 << 2) != 0
        _ = await OrbitPerformanceProbe.evaluate(anchor,
            "(()=>{globalThis.orbitR17Audio?.o.stop();globalThis.orbitR17Audio?.c.close();return {stopped:true}})()")

        _ = await OrbitPerformanceProbe.evaluate(tab,
            "(()=>{globalThis.orbitR17Events={freeze:0,resume:0,ticks:0};document.addEventListener('freeze',()=>orbitR17Events.freeze++);document.addEventListener('resume',()=>orbitR17Events.resume++);globalThis.orbitR17Timer=setInterval(()=>orbitR17Events.ticks++,100);return {started:true}})()")
        try? await Task.sleep(for: .milliseconds(350))
        let timerBeforeFreeze = await OrbitPerformanceProbe.evaluate(tab, "({ticks:orbitR17Events.ticks})")?["ticks"] as? Int ?? 0
        let hiddenVote = owner.engine.freezeTab(tab, frozen: true)
        try? await Task.sleep(for: .milliseconds(900))
        let releaseHiddenVote = owner.engine.freezeTab(tab, frozen: false)
        try? await Task.sleep(for: .milliseconds(500))
        let lifecycleEvents = await OrbitPerformanceProbe.evaluate(tab, "({freeze:orbitR17Events.freeze,resume:orbitR17Events.resume,ticks:orbitR17Events.ticks})") ?? [:]
        let freezeEvents = lifecycleEvents["freeze"] as? Int ?? 0
        let resumeEvents = lifecycleEvents["resume"] as? Int ?? 0
        let timerAfterUnfreeze = lifecycleEvents["ticks"] as? Int ?? 0
        let hiddenFreezeMask = lifecycle.lifecycle()?.cannotFreezeMask ?? UInt64.max
        let hiddenVotingBlockers = hiddenFreezeMask & ~(UInt64(1) << 22)
        result["freezeEventCount"] = freezeEvents
        result["resumeEventCount"] = resumeEvents
        result["hiddenFreezeVetoMask"] = hiddenFreezeMask
        result["runningFrozenRunning"] = hiddenVote && releaseHiddenVote && timerBeforeFreeze > 0 &&
            hiddenVotingBlockers == 0 && freezeEvents > 0 && resumeEvents > 0 && timerAfterUnfreeze > timerBeforeFreeze

        let fast = await owner.engine.purgeMemory(.fast)
        let aggressive = await owner.engine.purgeMemory(.aggressive)
        result["fastStatus"] = fast.status.rawValue
        result["fastMeasurements"] = fast.committedBeforeKB != nil && fast.committedAfterKB != nil
        result["fastElapsedMicroseconds"] = fast.elapsedMicroseconds ?? 0
        result["aggressiveStatus"] = aggressive.status.rawValue
        result["aggressiveMeasurements"] = aggressive.committedBeforeKB != nil && aggressive.committedAfterKB != nil
        result["aggressiveElapsedMicroseconds"] = aggressive.elapsedMicroseconds ?? 0
        let allocations = Task.detached(priority: .utility) {
            for _ in 0..<48 {
                guard let memory = malloc(256 * 1024) else { continue }
                memset(memory, 0x5a, 256 * 1024)
                usleep(1_000)
                free(memory)
            }
        }
        let concurrent = await owner.engine.purgeMemory(.fast)
        await allocations.value
        result["concurrentPurgeStatus"] = concurrent.status.rawValue
        result["concurrentPurgeElapsedMicroseconds"] = concurrent.elapsedMicroseconds ?? 0

        let profileID = tab.profileID
        let originURLs = ports.map { URL(string: "http://127.0.0.1:\($0)/")! }
        let firstAccepted = owner.engine.preconnect(profileID: profileID, to: originURLs[0], sockets: 2)
        let duplicateRejected = !owner.engine.preconnect(profileID: profileID, to: originURLs[0], sockets: 1)
        var accepted = [firstAccepted]
        for index in 1..<6 {
            accepted.append(owner.engine.preconnect(profileID: profileID, to: originURLs[index], sockets: 1))
        }
        let seventhRejected = !owner.engine.preconnect(profileID: profileID, to: originURLs[6], sockets: 1)
        let badSocketCountRejected = !owner.engine.preconnect(profileID: profileID, to: originURLs[6], sockets: 7)
        result["preconnectSixAccepted"] = accepted.count == 6 && accepted.allSatisfy { $0 }
        result["preconnectDuplicateRejected"] = duplicateRejected
        result["preconnectSeventhRejected"] = seventhRejected
        result["preconnectBadSocketCountRejected"] = badSocketCountRejected
        result["preconnectUnsupportedSchemeRejected"] = !owner.engine.preconnect(
            profileID: profileID, to: URL(fileURLWithPath: "/tmp/orbit-r17"), sockets: 1)

        let closeFreezeMask = lifecycle.lifecycle()?.cannotFreezeMask ?? UInt64.max
        let closeVotingBlockers = closeFreezeMask & ~(UInt64(1) << 22)
        let finalCloseVote = owner.engine.freezeTab(tab, frozen: true)
        try? await Task.sleep(for: .milliseconds(900))
        owner.session.closeOccurrence(occurrence)
        await owner.session.waitForPendingCommands()
        result["closeFreezeVetoMask"] = closeFreezeMask
        result["closeWhileFrozen"] = finalCloseVote && closeVotingBlockers == 0 && freezeEvents > 0 &&
            owner.session.surface(for: occurrence) == nil
        owner.session.closeOccurrence(anchorOccurrence)
        await owner.session.waitForPendingCommands()
        let emptyProcessPurge = await owner.engine.purgeMemory(.fast)
        result["emptyProcessPurgeStatus"] = emptyProcessPurge.status.rawValue
        result["emptyProcessPurgeElapsedMicroseconds"] = emptyProcessPurge.elapsedMicroseconds ?? 0
        return result
    }
}
