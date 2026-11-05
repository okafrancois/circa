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
        owner.session.openTab(url: url)
        await owner.session.waitForQueuedCommands()
        guard let tab = owner.session.selectedSurface, let occurrence = owner.session.snapshot?.selectedOccurrenceID,
              let lifecycle = tab.pagePerformance else { return ["missingSurface": true] }
        for sibling in owner.session.snapshot?.tabs ?? [] where sibling.occurrenceID != occurrence {
            owner.session.closeOccurrence(sibling.occurrenceID)
        }
        await owner.session.waitForPendingCommands()
        for _ in 0..<160 {
            if tab.isReady && !tab.navigationState.isLoading { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        var result: [String: Any] = [:]
        let visibleMask = lifecycle.lifecycle()?.cannotFreezeMask ?? 0
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

        _ = await OrbitPerformanceProbe.evaluate(tab,
            "(()=>{let c=new AudioContext(),o=c.createOscillator(),g=c.createGain();g.gain.value=.03;o.connect(g);g.connect(c.destination);o.start();globalThis.orbitR17Audio={c,o};return {started:true}})()")
        try? await Task.sleep(for: .milliseconds(350))
        let audibleMask = lifecycle.lifecycle()?.cannotFreezeMask ?? 0
        result["audibleVetoBit"] = audibleMask & (1 << 2) != 0
        _ = await OrbitPerformanceProbe.evaluate(tab,
            "(()=>{globalThis.orbitR17Audio?.o.stop();globalThis.orbitR17Audio?.c.close();return {stopped:true}})()")

        _ = await OrbitPerformanceProbe.evaluate(tab,
            "(()=>{globalThis.orbitR17Ticks=0;globalThis.orbitR17Timer=setInterval(()=>orbitR17Ticks++,100);return {started:true}})()")
        try? await Task.sleep(for: .milliseconds(350))
        let timerBeforeFreeze = await OrbitPerformanceProbe.evaluate(tab, "({ticks:orbitR17Ticks})")?["ticks"] as? Int ?? 0
        owner.window?.orderOut(nil)
        let hiddenVote = owner.engine.freezeTab(tab, frozen: true)
        try? await Task.sleep(for: .seconds(2))
        let timerDuringFreeze = await OrbitPerformanceProbe.evaluate(tab, "({ticks:orbitR17Ticks})")?["ticks"] as? Int ?? -1
        let releaseHiddenVote = owner.engine.freezeTab(tab, frozen: false)
        try? await Task.sleep(for: .milliseconds(600))
        let timerAfterUnfreeze = await OrbitPerformanceProbe.evaluate(tab, "({ticks:orbitR17Ticks})")?["ticks"] as? Int ?? -1
        result["runningFrozenRunning"] = hiddenVote && releaseHiddenVote && timerBeforeFreeze > 0 &&
            timerDuringFreeze == timerBeforeFreeze && timerAfterUnfreeze > timerDuringFreeze
        owner.window?.makeKeyAndOrderFront(nil)

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

        owner.window?.orderOut(nil)
        let finalCloseVote = owner.engine.freezeTab(tab, frozen: true)
        try? await Task.sleep(for: .seconds(2))
        let frozenTicksBeforeClose = await OrbitPerformanceProbe.evaluate(tab, "({ticks:orbitR17Ticks})")?["ticks"] as? Int ?? -1
        try? await Task.sleep(for: .milliseconds(600))
        let frozenTicksAfterClose = await OrbitPerformanceProbe.evaluate(tab, "({ticks:orbitR17Ticks})")?["ticks"] as? Int ?? -2
        owner.session.closeOccurrence(occurrence)
        await owner.session.waitForPendingCommands()
        result["closeWhileFrozen"] = finalCloseVote && frozenTicksBeforeClose > 0 &&
            frozenTicksAfterClose == frozenTicksBeforeClose && owner.session.surface(for: occurrence) == nil
        owner.window?.makeKeyAndOrderFront(nil)
        let emptyProcessPurge = await owner.engine.purgeMemory(.fast)
        result["emptyProcessPurgeStatus"] = emptyProcessPurge.status.rawValue
        result["emptyProcessPurgeElapsedMicroseconds"] = emptyProcessPurge.elapsedMicroseconds ?? 0
        return result
    }
}
