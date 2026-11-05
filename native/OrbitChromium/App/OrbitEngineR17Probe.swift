import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Darwin

/// Runtime checks for the additive v17 engine surface in a confined synthetic bundle.
@MainActor
enum OrbitEngineR17Probe {
    private enum BoundedOutcome<Value: Sendable>: Sendable {
        case completed(Value)
        case timedOut
    }

    private final class BoundedRace<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<BoundedOutcome<Value>, Never>?
        private var completed = false
        private var operationTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<BoundedOutcome<Value>, Never>) {
            self.continuation = continuation
        }

        func install(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                operation.cancel()
                timeout.cancel()
                return
            }
            operationTask = operation
            timeoutTask = timeout
            lock.unlock()
        }

        func finish(_ outcome: BoundedOutcome<Value>) {
            lock.lock()
            guard !completed, let continuation else {
                lock.unlock()
                return
            }
            completed = true
            self.continuation = nil
            let operation = operationTask
            let timeout = timeoutTask
            lock.unlock()
            continuation.resume(returning: outcome)
            operation?.cancel()
            timeout?.cancel()
        }
    }

    @MainActor
    private final class ProgressTrace {
        private var steps: [[String: Any]] = []
        private let publish: ([String: Any]) -> Void
        var snapshot: [String: Any] { ["steps": steps] }

        init(publish: @escaping ([String: Any]) -> Void) {
            self.publish = publish
        }

        func perform<Value: Sendable>(
            _ name: String,
            timeout: Duration = .seconds(2),
            operation: @escaping @MainActor @Sendable () async -> Value
        ) async -> Value? {
            let index = steps.count
            let started = ProcessInfo.processInfo.systemUptime
            steps.append([
                "name": name,
                "startUptime": started,
                "endUptime": NSNull(),
                "result": "running",
                "status": "running"
            ])
            publish(["activeStep": name, "steps": steps, "updatedAtUptime": started])

            let outcome = await Self.bounded(timeout: timeout, operation: operation)
            let ended = ProcessInfo.processInfo.systemUptime
            switch outcome {
            case .completed(let value):
                steps[index]["endUptime"] = ended
                steps[index]["result"] = String(describing: value)
                steps[index]["status"] = "completed"
                publish(["activeStep": NSNull(), "steps": steps, "updatedAtUptime": ended])
                return value
            case .timedOut:
                steps[index]["endUptime"] = ended
                steps[index]["result"] = "timed out after \(timeout)"
                steps[index]["status"] = "timedOut"
                publish(["activeStep": NSNull(), "steps": steps, "updatedAtUptime": ended])
                return nil
            }
        }

        private static func bounded<Value: Sendable>(
            timeout: Duration,
            operation: @escaping @MainActor @Sendable () async -> Value
        ) async -> BoundedOutcome<Value> {
            await withCheckedContinuation { continuation in
                let race = BoundedRace<Value>(continuation)
                let operationTask = Task { @MainActor in
                    race.finish(.completed(await operation()))
                }
                let timeoutTask = Task { @MainActor in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    race.finish(.timedOut)
                }
                race.install(operation: operationTask, timeout: timeoutTask)
            }
        }
    }

    private struct PurgeMetrics: Sendable {
        let status: Int32
        let measuredBefore: Bool
        let measuredAfter: Bool
        let elapsedMicroseconds: UInt64
    }

    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.engine-r17",
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              let window = owner.window, NSApp.windows.contains(where: { $0 === window }) else { return false }
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }

    private static func evaluateJSON(_ surface: ChromiumSurface, _ expression: String) async -> String {
        guard let value = await OrbitPerformanceProbe.evaluate(surface, expression, timeout: .seconds(2)),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    static func run(
        _ owner: OrbitWindowController,
        command: [String: String],
        progress: @escaping ([String: Any]) -> Void
    ) async -> [String: Any] {
        let trace = ProgressTrace(publish: progress)
        var result: [String: Any] = [:]
        let text = command["url"] ?? ""
        let url = URL(string: text)
        let ports = command["ports"]?.split(separator: ",").compactMap { Int($0) } ?? []
        let admitted = await trace.perform("admission.synthetic_owner_and_loopback_fixture") {
            owns(owner) && url?.scheme == "http" && url?.host == "127.0.0.1" && ports.count == 7
        } ?? false
        guard admitted, let url else { return ["ownershipOrFixtureRefused": true] }
        guard let anchor = owner.session.selectedSurface,
              let anchorOccurrence = owner.session.snapshot?.selectedOccurrenceID,
              let anchorLifecycle = anchor.pagePerformance else {
            return ["missingAnchor": true]
        }

        let delegate = FreezeDelegate()
        guard let tab = await trace.perform("freeze.create_background_surface", timeout: .seconds(3), operation: {
            owner.engine.makeSurface(profileID: anchor.profileID, delegate: delegate)
        }) else { return ["missingBackgroundSurface": true] }
        defer {
            if !tab.isDisposed {
                _ = owner.engine.freezeTab(tab, frozen: false)
                tab.dispose()
            }
            withExtendedLifetime(delegate) {}
        }

        let loaded = await trace.perform("freeze.load_background_loopback", timeout: .seconds(5)) {
            tab.navigate(to: url)
            for _ in 0..<160 {
                if tab.isReady && !tab.navigationState.isLoading { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return tab.isReady && !tab.navigationState.isLoading
        } ?? false
        guard loaded, let lifecycle = tab.pagePerformance else { return ["missingBackgroundSurface": true] }

        let visibleMask = await trace.perform("freeze.read_visible_page_lifecycle_mask") {
            anchorLifecycle.lifecycle()?.cannotFreezeMask ?? UInt64.max
        } ?? UInt64.max
        result["visibleVetoBit"] = visibleMask & (1 << 0) != 0

        let initialVote = await trace.perform("freeze.add_vote") {
            owner.engine.freezeTab(tab, frozen: true)
        } ?? false
        let initialMask = await trace.perform("freeze.read_mask_while_vote_held") {
            lifecycle.lifecycle()?.cannotFreezeMask ?? UInt64.max
        } ?? UInt64.max
        let removeVote = await trace.perform("freeze.remove_vote_before_javascript") {
            owner.engine.freezeTab(tab, frozen: false)
        } ?? false
        let readdVote = await trace.perform("freeze.readd_vote") {
            owner.engine.freezeTab(tab, frozen: true)
        } ?? false
        let readdedMask = await trace.perform("freeze.read_readded_vote_mask") {
            lifecycle.lifecycle()?.cannotFreezeMask ?? UInt64.max
        } ?? UInt64.max
        let finalVoteRemoval = await trace.perform("freeze.remove_readded_vote_before_javascript") {
            owner.engine.freezeTab(tab, frozen: false)
        } ?? false
        result["freezeAddRemoveReadd"] = initialVote && removeVote && readdVote && finalVoteRemoval
        result["freezeMaskWhileVoted"] = initialMask
        result["freezeMaskAfterReadd"] = readdedMask

        let lockStart = await trace.perform("freeze.weblock_start_javascript", timeout: .seconds(3)) {
            object(await evaluateJSON(tab,
                "navigator.locks.request('orbit-r17-freeze-smoke',()=>new Promise(r=>globalThis.releaseOrbitR17Lock=r));({started:true})"))["started"] as? Bool ?? false
        } ?? false
        _ = await trace.perform("freeze.weblock_settle", timeout: .seconds(1)) {
            try? await Task.sleep(for: .milliseconds(250))
            return true
        }
        let webLockMask = await trace.perform("freeze.read_weblock_lifecycle_mask_without_vote") {
            lifecycle.lifecycle()?.cannotFreezeMask ?? UInt64.max
        } ?? UInt64.max
        result["webLockVetoBit"] = webLockMask & (1 << 5) != 0
        let webLockVote = await trace.perform("freeze.weblock_vote") {
            owner.engine.freezeTab(tab, frozen: true)
        } ?? false
        let webLockVotedMask = await trace.perform("freeze.read_weblock_mask_while_vote_held") {
            lifecycle.lifecycle()?.cannotFreezeMask ?? UInt64.max
        } ?? UInt64.max
        let webLockVoteRemoval = await trace.perform("freeze.weblock_remove_vote_before_javascript") {
            owner.engine.freezeTab(tab, frozen: false)
        } ?? false
        let lockRelease = await trace.perform("freeze.weblock_release_javascript", timeout: .seconds(3)) {
            object(await evaluateJSON(tab, "globalThis.releaseOrbitR17Lock?.();({released:true})"))["released"] as? Bool ?? false
        } ?? false
        result["webLockVoteAccepted"] = webLockVote
        result["webLockVotedMask"] = webLockVotedMask
        result["webLockReleased"] = lockStart && webLockVoteRemoval && lockRelease

        let anchorNavigated = await trace.perform("freeze.navigate_visible_anchor", timeout: .seconds(5)) {
            anchor.navigate(to: url)
            for _ in 0..<160 {
                if !anchor.navigationState.isLoading && anchor.navigationState.committedURL == url { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return !anchor.navigationState.isLoading && anchor.navigationState.committedURL == url
        } ?? false
        let audibleStarted = await trace.perform("freeze.audible_start_javascript", timeout: .seconds(3)) {
            object(await evaluateJSON(anchor,
                "(()=>{let c=new AudioContext(),o=c.createOscillator(),g=c.createGain();g.gain.value=.03;o.connect(g);g.connect(c.destination);o.start();globalThis.orbitR17Audio={c,o};return {started:true}})()"))["started"] as? Bool ?? false
        } ?? false
        _ = await trace.perform("freeze.audible_settle", timeout: .seconds(1)) {
            try? await Task.sleep(for: .milliseconds(350))
            return true
        }
        let audibleMask = await trace.perform("freeze.read_audible_lifecycle_mask") {
            anchorLifecycle.lifecycle()?.cannotFreezeMask ?? UInt64.max
        } ?? UInt64.max
        result["audibleVetoBit"] = audibleMask & (1 << 2) != 0
        let audibleStopped = await trace.perform("freeze.audible_stop_javascript", timeout: .seconds(3)) {
            object(await evaluateJSON(anchor,
                "(()=>{globalThis.orbitR17Audio?.o.stop();globalThis.orbitR17Audio?.c.close();return {stopped:true}})()"))["stopped"] as? Bool ?? false
        } ?? false
        result["audibleLifecycleExercised"] = anchorNavigated && audibleStarted && audibleStopped

        let timerStarted = await trace.perform("freeze.timer_start_javascript", timeout: .seconds(3)) {
            object(await evaluateJSON(tab,
                "(()=>{globalThis.orbitR17Events={freeze:0,resume:0,ticks:0};document.addEventListener('freeze',()=>orbitR17Events.freeze++);document.addEventListener('resume',()=>orbitR17Events.resume++);globalThis.orbitR17Timer=setInterval(()=>orbitR17Events.ticks++,100);return {started:true}})()"))["started"] as? Bool ?? false
        } ?? false
        _ = await trace.perform("freeze.timer_warmup", timeout: .seconds(1)) {
            try? await Task.sleep(for: .milliseconds(350))
            return true
        }
        let timerBeforeJSON = await trace.perform("freeze.timer_read_before_vote", timeout: .seconds(3)) {
            await evaluateJSON(tab, "({ticks:orbitR17Events.ticks})")
        } ?? ""
        let timerBefore = object(timerBeforeJSON)["ticks"] as? Int ?? 0
        let hiddenVote = await trace.perform("freeze.add_hidden_vote") {
            owner.engine.freezeTab(tab, frozen: true)
        } ?? false
        _ = await trace.perform("freeze.hidden_vote_wait", timeout: .seconds(2)) {
            try? await Task.sleep(for: .milliseconds(900))
            return true
        }
        let hiddenFreezeMask = await trace.perform("freeze.read_lifecycle_mask_while_frozen") {
            lifecycle.lifecycle()?.cannotFreezeMask ?? UInt64.max
        } ?? UInt64.max
        let releaseHiddenVote = await trace.perform("freeze.remove_hidden_vote_before_javascript") {
            owner.engine.freezeTab(tab, frozen: false)
        } ?? false
        _ = await trace.perform("freeze.resume_settle", timeout: .seconds(1)) {
            try? await Task.sleep(for: .milliseconds(500))
            return true
        }
        let lifecycleEventsJSON = await trace.perform("freeze.read_events_after_unfreeze_javascript", timeout: .seconds(3)) {
            await evaluateJSON(tab, "({freeze:orbitR17Events.freeze,resume:orbitR17Events.resume,ticks:orbitR17Events.ticks})")
        } ?? ""
        let lifecycleEvents = object(lifecycleEventsJSON)
        let freezeEvents = lifecycleEvents["freeze"] as? Int ?? 0
        let resumeEvents = lifecycleEvents["resume"] as? Int ?? 0
        let timerAfterUnfreeze = lifecycleEvents["ticks"] as? Int ?? 0
        let hiddenVotingBlockers = hiddenFreezeMask & ~(UInt64(1) << 22)
        result["freezeEventCount"] = freezeEvents
        result["resumeEventCount"] = resumeEvents
        result["hiddenFreezeVetoMask"] = hiddenFreezeMask
        result["runningFrozenRunning"] = timerStarted && hiddenVote && releaseHiddenVote && timerBefore > 0 &&
            hiddenVotingBlockers == 0 && freezeEvents > 0 && resumeEvents > 0 && timerAfterUnfreeze > timerBefore

        let fast = await trace.perform("purge.fast_before_explicit_dump", timeout: .seconds(5)) {
            await owner.engine.purgeMemory(.fast)
        }
        result["fastStatus"] = fast?.status.rawValue ?? 0
        result["fastMeasurements"] = fast?.committedBeforeKB != nil && fast?.committedAfterKB != nil
        result["fastElapsedMicroseconds"] = fast?.elapsedMicroseconds ?? 0
        let dump = await trace.perform("purge.explicit_memory_dump", timeout: .seconds(5)) {
            await anchorLifecycle.memoryDump()
        }
        result["memoryDumpStatus"] = dump?.status.rawValue ?? -1
        let aggressive = await trace.perform("purge.aggressive", timeout: .seconds(5)) {
            await owner.engine.purgeMemory(.aggressive)
        }
        result["aggressiveStatus"] = aggressive?.status.rawValue ?? 0
        result["aggressiveMeasurements"] = aggressive?.committedBeforeKB != nil && aggressive?.committedAfterKB != nil
        result["aggressiveElapsedMicroseconds"] = aggressive?.elapsedMicroseconds ?? 0

        let allocationsComplete = await trace.perform("purge.concurrent_allocation", timeout: .seconds(2)) {
            let allocations = Task.detached(priority: .utility) {
                for _ in 0..<48 {
                    guard let memory = malloc(256 * 1024) else { continue }
                    memset(memory, 0x5a, 256 * 1024)
                    usleep(1_000)
                    free(memory)
                }
            }
            await allocations.value
            return true
        } ?? false
        let concurrent = await trace.perform("purge.fast_during_allocation", timeout: .seconds(5)) {
            await owner.engine.purgeMemory(.fast)
        }
        result["allocationCompleted"] = allocationsComplete
        result["concurrentPurgeStatus"] = concurrent?.status.rawValue ?? 0
        result["concurrentPurgeElapsedMicroseconds"] = concurrent?.elapsedMicroseconds ?? 0

        let profileID = tab.profileID
        let originURLs = ports.map { URL(string: "http://127.0.0.1:\($0)/")! }
        var accepted: [Bool] = []
        for index in 0..<6 {
            let acceptedRequest = await trace.perform("preconnect.accept_\(index + 1)") {
                owner.engine.preconnect(profileID: profileID, to: originURLs[index], sockets: index == 0 ? 2 : 1)
            } ?? false
            accepted.append(acceptedRequest)
        }
        let duplicateRejected = await trace.perform("preconnect.reject_duplicate") {
            !owner.engine.preconnect(profileID: profileID, to: originURLs[0], sockets: 1)
        } ?? false
        let seventhRejected = await trace.perform("preconnect.reject_seventh") {
            !owner.engine.preconnect(profileID: profileID, to: originURLs[6], sockets: 1)
        } ?? false
        let badSocketCountRejected = await trace.perform("preconnect.reject_socket_count") {
            !owner.engine.preconnect(profileID: profileID, to: originURLs[6], sockets: 7)
        } ?? false
        let unsupportedSchemeRejected = await trace.perform("preconnect.reject_unsupported_scheme") {
            !owner.engine.preconnect(profileID: profileID,
                to: URL(fileURLWithPath: "/tmp/orbit-r17"), sockets: 1)
        } ?? false
        result["preconnectSixAccepted"] = accepted.count == 6 && accepted.allSatisfy { $0 }
        result["preconnectDuplicateRejected"] = duplicateRejected
        result["preconnectSeventhRejected"] = seventhRejected
        result["preconnectBadSocketCountRejected"] = badSocketCountRejected
        result["preconnectUnsupportedSchemeRejected"] = unsupportedSchemeRejected

        let privateEngine = makePrivateEngine()
        let privateProfileID = ProfileID()
        let privatePrepared = await trace.perform("preconnect.private_profile_prepare", timeout: .seconds(7)) {
            privateEngine.profile(for: privateProfileID)
            await privateEngine.profileReady(privateProfileID)
            do {
                try await privateEngine.preparePrivateProfile(privateProfileID)
                return true
            } catch {
                return false
            }
        } ?? false
        var privateRefused = false
        if privatePrepared {
            privateRefused = await trace.perform("preconnect.private_profile_refusal") {
                !privateEngine.preconnect(profileID: privateProfileID, to: originURLs[6], sockets: 1)
            } ?? false
        }
        result["preconnectPrivateProfile"] = privateRefused
        if privatePrepared {
            _ = await trace.perform("preconnect.private_profile_release", timeout: .seconds(12)) {
                do {
                    try await privateEngine.releasePrivateProfile(privateProfileID)
                    return true
                } catch {
                    return false
                }
            }
        }
        await privateEngine.shutdown()
        result["preconnectPreferenceOff"] = "not exercised: no synthetic network_prediction_options mutation seam"

        let closeFreezeMask = await trace.perform("freeze.read_close_lifecycle_mask") {
            lifecycle.lifecycle()?.cannotFreezeMask ?? UInt64.max
        } ?? UInt64.max
        let finalCloseVote = await trace.perform("freeze.add_vote_before_close") {
            owner.engine.freezeTab(tab, frozen: true)
        } ?? false
        _ = await trace.perform("freeze.close_vote_settle", timeout: .seconds(2)) {
            try? await Task.sleep(for: .milliseconds(300))
            return true
        }
        let disposed = await trace.perform("freeze.dispose_while_voted") {
            tab.dispose()
            return tab.isDisposed
        } ?? false
        let teardownComplete = await trace.perform("freeze.wait_for_teardown", timeout: .seconds(5)) {
            for _ in 0..<200 {
                if tab.isTeardownComplete { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return tab.isTeardownComplete
        } ?? false
        let closeVotingBlockers = closeFreezeMask & ~(UInt64(1) << 22)
        result["closeFreezeVetoMask"] = closeFreezeMask
        result["closeWhileFrozen"] = finalCloseVote && closeVotingBlockers == 0 && disposed && teardownComplete

        owner.session.closeOccurrence(anchorOccurrence)
        await owner.session.waitForPendingCommands()
        let emptyProcessPurge = await trace.perform("purge.empty_process_fast", timeout: .seconds(5)) {
            await owner.engine.purgeMemory(.fast)
        }
        result["emptyProcessPurgeStatus"] = emptyProcessPurge?.status.rawValue ?? 0
        result["emptyProcessPurgeElapsedMicroseconds"] = emptyProcessPurge?.elapsedMicroseconds ?? 0
        result["timedOutSteps"] = (trace.snapshot["steps"] as? [[String: Any]] ?? []).compactMap {
            ($0["status"] as? String) == "timedOut" ? $0["name"] as? String : nil
        }
        return result
    }

    private final class FreezeDelegate: BrowserEngineSurfaceDelegate {
        func surfaceDidStartNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidFinishNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidFailNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidRequestClose(_ surface: ChromiumSurface) {}
        func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                     decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
            decision.decide(action.url?.scheme == "http" && action.url?.host == "127.0.0.1" ? .allow : .cancel)
        }
        func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                     make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
        func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
    }
}
