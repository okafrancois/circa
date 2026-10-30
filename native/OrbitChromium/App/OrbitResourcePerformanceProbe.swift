import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Darwin

/// Confined diagnostics: no command can enable this endpoint in a production bundle.
@MainActor
enum OrbitResourcePerformanceProbe {
    static func run(_ owner: OrbitWindowController, store: BrowserStore, command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.perf-coord-0",
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true else { return ["refused": true] }
        let coordinator = owner.resources.coordinator
        let step = command["step"] ?? "snapshot"
        if step == "fixture" {
            guard let text = command["url"], let base = URL(string: text), base.scheme == "http", base.host == "127.0.0.1" else {
                return ["fixtureRefused": true]
            }
            owner.window?.orderOut(nil)
            for tab in owner.session.snapshot?.tabs ?? [] { owner.session.closeOccurrence(tab.occurrenceID) }
            await owner.session.waitForPendingCommands()
            var profiles: [ProfileID] = []
            for index in 0..<3 { profiles.append(await store.createProfile(name: "Synthetic resource profile \(index)")) }
            for spaceIndex in 0..<5 {
                guard let space = try? await store.createSpace(name: "Synthetic resources \(spaceIndex)", profileID: profiles[spaceIndex % 3]) else { continue }
                owner.session.activateSpace(space)
                await owner.session.waitForPendingCommands()
                for index in 0..<(spaceIndex < 2 ? 13 : 12) {
                    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                    components.host = "resource-\(spaceIndex)-\(index).localhost"
                    let url = components.url!.appendingPathComponent("space-\(spaceIndex)/tab-\(index)")
                    owner.session.openTab(url: url)
                    await owner.session.waitForPendingCommands()
                }
            }
            for _ in 0..<200 {
                if owner.session.ownedSurfaces.allSatisfy({ $0.isReady && !$0.navigationState.isLoading }) { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            if let window = owner.window {
                window.collectionBehavior.insert(.moveToActiveSpace)
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            try? await Task.sleep(for: .milliseconds(300))
        } else if step == "native-discard" {
            guard let victim = owner.session.ownedSurfaces.first(where: {
                $0.profileID == owner.session.activeProfileID && $0 !== owner.session.selectedSurface && !$0.isSuspended
                    && BrowserPageSuspensionPolicy.refusal($0.pagePerformance?.lifecycle()) == nil
            }), let url = victim.currentURL else { return ["noVictim": true] }
            // Chromium's diagnostic page invokes its native discard mechanism with age ignored.
            // This is an external native discard, not an embedder suspension or global pressure.
            let delegate = DiagnosticsDelegate()
            let diagnostics = owner.engine.makeSurface(profileID: victim.profileID, delegate: delegate)
            defer { diagnostics.dispose(); withExtendedLifetime(delegate) {} }
            diagnostics.navigate(to: URL(string: "chrome://discards")!)
            for _ in 0..<160 {
                if diagnostics.isReady && diagnostics.navigationState.committedURL?.host == "discards"
                    && !diagnostics.navigationState.isLoading { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            let quoted = String(data: (try? JSONSerialization.data(withJSONObject: [url.absoluteString])) ?? Data(), encoding: .utf8) ?? "[]"
            let expression = """
            (async()=>{const m=await import('chrome://discards/discards.js');const p=m.getOrCreateDetailsProvider();
            const r=await p.getTabDiscardsInfo();const t=r.infos.find(t=>t.tabUrl===\(quoted)[0]);
            if(!t)return {found:false};await p.discardById(t.id,1);return {found:true};})()
            """
            let params: [String: Any] = ["expression": expression, "returnByValue": true, "awaitPromise": true]
            let bytes = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
            let reply = await diagnostics.devToolsCall("Runtime.evaluate", params: String(data: bytes, encoding: .utf8) ?? "{}")
            try? await Task.sleep(for: .milliseconds(250))
            var result = snapshot(owner)
            result["nativeCallAccepted"] = reply.0
            result["nativeReply"] = (try? JSONSerialization.jsonObject(with: reply.1)) ?? [:]
            result["victimDiscarded"] = victim.pagePerformance?.lifecycle()?.state == .discarded
            return result
        } else if step == "policy-suspend" {
            let count = await owner.tabSuspension.sweep(now: ProcessInfo.processInfo.systemUptime + 3601)
            try? await Task.sleep(for: .milliseconds(200))
            var result = snapshot(owner); result["sweepDiscards"] = count
            return result
        } else if step == "wake" {
            guard let surface = owner.session.ownedSurfaces.first(where: \.isSuspended),
                  let id = owner.session.occurrenceID(for: surface) else { return ["noSleeper": true] }
            let document = await store.sessionDocument()
            if let tab = document.tabs.first(where: { $0.occurrenceID == id }) {
                owner.session.activateSpace(tab.spaceID)
                await owner.session.waitForPendingCommands()
            }
            owner.session.selectOccurrence(id)
            await owner.session.waitForPendingCommands()
            await loaded(surface)
            try? await Task.sleep(for: .milliseconds(200))
        } else if step == "benchmark" {
            let original = coordinator.enabled
            defer { coordinator.enabled = original; owner.resources.reconcile() }
            var trials: [[String: Any]] = []
            for enabled in [false, true, true, false] {
                coordinator.enabled = enabled
                owner.resources.reconcile()
                try? await Task.sleep(for: .milliseconds(250))
                let startCPU = cpuSeconds(), start = ProcessInfo.processInfo.systemUptime
                try? await Task.sleep(for: .seconds(2))
                let elapsed = ProcessInfo.processInfo.systemUptime - start, cpu = cpuSeconds() - startCPU
                var sweeps: [Double] = []
                for _ in 0..<30 {
                    let begin = ProcessInfo.processInfo.systemUptime
                    owner.resources.sweep()
                    sweeps.append((ProcessInfo.processInfo.systemUptime - begin) * 1000)
                }
                trials.append(["enabled": enabled, "idleCPUPercent": 100 * cpu / elapsed,
                    "idleSeconds": elapsed, "sweepMainMS": sweeps, "occlusion": occlusion(owner)])
            }
            return ["trials": trials]
        } else if step == "observation" {
            coordinator.enabled = command["enabled"] != "false"
            owner.resources.reconcile()
        }
        var result = snapshot(owner)
        if step == "fixture" {
            let document = await store.sessionDocument()
            result["loadedTabs"] = owner.session.ownedSurfaces.filter { $0.isReady && !$0.navigationState.isLoading }.count
            result["modelTabs"] = document.tabs.count
            result["modelSpaces"] = Set(document.tabs.map(\.spaceID)).count
            result["modelProfiles"] = Set(coordinator.tabs.values.map(\.profile)).count
        }
        return result
    }

    private final class DiagnosticsDelegate: BrowserEngineSurfaceDelegate {
        func surfaceDidStartNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidFinishNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidFailNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidRequestClose(_ surface: ChromiumSurface) {}
        func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                     decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
            decision.decide(action.url?.absoluteString == "about:blank"
                || (action.url?.scheme == "chrome" && action.url?.host == "discards") ? .allow : .cancel)
        }
        func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                     make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
        func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
    }
    private static func loaded(_ surface: ChromiumSurface) async {
        for _ in 0..<160 {
            if surface.isReady && !surface.navigationState.isLoading { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    static func occlusion(_ owner: OrbitWindowController) -> [String: Any] {
        guard let window = owner.window else { return ["valid": false] }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let index = list.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }),
              let bounds = list[index][kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return ["valid": false, "visible": window.isVisible] }
        let covering = list[..<index].filter { item in
            guard (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let other = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.intersects(other)
        }
        return ["valid": covering.isEmpty && window.occlusionState.contains(.visible),
            "visible": window.isVisible, "appKitVisible": window.occlusionState.contains(.visible), "coveringWindows": covering.count]
    }
    private static func snapshot(_ owner: OrbitWindowController) -> [String: Any] {
        owner.resources.reconcile()
        let coordinator = owner.resources.coordinator
        coordinator.sampleMemory()
        let now = ProcessInfo.processInfo.systemUptime
        let surfaces = owner.session.ownedSurfaces
        let tabs = coordinator.tabs.values.map { tab -> [String: Any] in
            let state = tab.lifecycle
            let actual = surfaces.first { ObjectIdentifier($0) == tab.identity }
            let protection: [String: Any] = ["media": state?.playingMedia ?? false, "video": state?.playingVideo ?? false,
                "audioContext": state?.audioContextRunning ?? false, "audible": state?.audible ?? false,
                "pip": state?.pictureInPicture ?? false, "capture": state?.capturing ?? 0,
                "form": state?.hadFormInteraction ?? false, "edits": state?.hadUserEdits ?? false,
                "webLock": state?.webLock ?? false, "idbLock": state?.indexedDBLock ?? false, "webRTC": state?.webRTC ?? false]
            return ["occurrence": tab.occurrence.rawValue.uuidString, "window": tab.window.uuidString,
                "profile": tab.profile.rawValue.uuidString, "state": tab.state, "visible": tab.visible, "selected": tab.selected,
                "secondsSinceVisible": tab.secondsSinceVisible(at: now), "reasonMask": state?.cannotDiscardMask ?? 0,
                "footprintEstimateKB": state?.footprintKB ?? 0, "rendererPID": state?.rendererPID ?? 0,
                "documentID": state?.documentID ?? 0, "lastDiscard": tab.lastDiscard.rawValue,
                "nativeDiscards": tab.nativeDiscards, "policyDiscards": tab.policyDiscards,
                "protections": protection, "shellAllowsSuspension": tab.engineAllowsSuspension as Any? ?? NSNull(),
                "protected": tab.protected, "nativeRefusal": BrowserPageSuspensionPolicy.refusal(state) ?? "none",
                "matchesEngine": actual.map { $0.pagePerformance?.lifecycle() == state && $0.isSuspended == tab.sleeping } ?? false]
        }
        return ["tabs": tabs, "global": coordinator.summary(),
            "windows": Dictionary(uniqueKeysWithValues: Set(coordinator.tabs.values.map(\.window)).map {
                ($0.uuidString, coordinator.summary(window: $0))
            }), "ownedSurfaces": surfaces.count, "nativeDiscards": coordinator.nativeDiscards,
            "policyDiscards": coordinator.policyDiscards, "pressureEvents": coordinator.pressureEvents,
            "pressureLevel": coordinator.pressureLevel, "memorySampleUptime": coordinator.memorySampleUptime ?? 0,
            "processes": coordinator.processes.map { ["pid": $0.pid, "footprintBytes": $0.footprint as Any? ?? NSNull(),
                "alive": kill($0.pid, 0) == 0] as [String: Any] },
            "counters": BrowserPerformance.counters, "occlusion": occlusion(owner)]
    }
}
