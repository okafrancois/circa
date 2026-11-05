import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

/// Focused runtime checks for the frozen E1/E4 qualification follow-up.
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

    private struct LifecycleSample: Sendable, CustomStringConvertible {
        let state: Int32?
        let mask: UInt64?
        let audible: Bool?
        let playingMedia: Bool?
        let audioContextRunning: Bool?
        let webLock: Bool?
        let indexedDBLock: Bool?
        let webRTC: Bool?
        let capturing: UInt32?
        let rendererPID: Int32?
        let documentID: UInt64?
        let uptime: Double

        var stateName: String {
            switch state {
            case 0: "running"
            case 1: "frozen"
            case 2: "discarded"
            default: "unavailable"
            }
        }

        var decodedReasons: [String] {
            guard let mask else { return ["unavailable"] }
            return Self.reasonNames.enumerated().compactMap { bit, name in
                mask & (UInt64(1) << bit) == 0 ? nil : name
            }
        }

        var maskHex: String { mask.map { "0x" + String($0, radix: 16) } ?? "unavailable" }

        var dictionary: [String: Any] {
            [
                "sampleUptime": uptime,
                "state": stateName,
                "stateRawValue": state.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "cannotFreezeMask": mask.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "cannotFreezeMaskHex": maskHex,
                "decodedCannotFreezeReasons": decodedReasons,
                "audible": audible.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "playingMedia": playingMedia.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "audioContextRunning": audioContextRunning.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "webLock": webLock.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "indexedDBLock": indexedDBLock.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "webRTC": webRTC.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "capturing": capturing.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "rendererPID": rendererPID.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "documentID": documentID.map { NSNumber(value: $0) as Any } ?? NSNull()
            ]
        }

        var description: String { "state=\(stateName), mask=\(maskHex), reasons=\(decodedReasons)" }

        static func read(_ performance: (any BrowserPagePerformance)?) -> Self {
            let now = ProcessInfo.processInfo.systemUptime
            guard let value = performance?.lifecycle() else {
                return .init(state: nil, mask: nil, audible: nil, playingMedia: nil,
                    audioContextRunning: nil, webLock: nil, indexedDBLock: nil, webRTC: nil,
                    capturing: nil, rendererPID: nil, documentID: nil, uptime: now)
            }
            return .init(state: value.state.rawValue, mask: value.cannotFreezeMask,
                audible: value.audible, playingMedia: value.playingMedia,
                audioContextRunning: value.audioContextRunning, webLock: value.webLock,
                indexedDBLock: value.indexedDBLock, webRTC: value.webRTC,
                capturing: value.capturing, rendererPID: value.rendererPID,
                documentID: value.documentID, uptime: now)
        }

        private static let reasonNames = [
            "kVisible", "kRecentlyVisible", "kAudible", "kRecentlyAudible",
            "kFreezingOriginTrialOptOut", "kHoldingWebLock", "kHoldingIndexedDBLock",
            "kHoldingBlockingIndexedDBLock", "kConnectedToUsbDevice",
            "kConnectedToBluetoothDevice", "kConnectedToHidDevice", "kConnectedToSerialPort",
            "kCapturingVideo", "kCapturingAudio", "kBeingMirrored", "kCapturingWindow",
            "kCapturingDisplay", "kWebRTC", "kLoading", "kNotificationPermission",
            "kOptedOut", "kMostRecentlyUsed", "kWebUI"
        ]
    }

    private struct PollResult: Sendable, CustomStringConvertible {
        let reached: Bool
        let target: String
        let samples: Int
        let last: LifecycleSample
        var description: String { "reached=\(reached), target=\(target), samples=\(samples), last={\(last)}" }
        var dictionary: [String: Any] {
            ["reached": reached, "target": target, "samples": samples, "last": last.dictionary]
        }
    }

    @MainActor
    private final class ProgressTrace {
        private var steps: [[String: Any]] = []
        private let publish: ([String: Any]) -> Void
        private let deadline = ProcessInfo.processInfo.systemUptime + 36

        init(publish: @escaping ([String: Any]) -> Void) { self.publish = publish }
        var snapshot: [[String: Any]] { steps }

        func perform<Value: Sendable>(
            _ name: String,
            timeout: Duration = .seconds(3),
            operation: @escaping @MainActor @Sendable () async -> Value
        ) async -> Value? {
            let index = steps.count
            let started = ProcessInfo.processInfo.systemUptime
            steps.append(["name": name, "startUptime": started, "endUptime": NSNull(),
                          "result": "running", "status": "running"])
            publish(["activeStep": name, "steps": steps, "updatedAtUptime": started])

            let remaining = deadline - started
            guard remaining > 0 else {
                steps[index]["endUptime"] = started
                steps[index]["result"] = "probe-wide 36-second deadline exhausted"
                steps[index]["status"] = "timedOut"
                publish(["activeStep": NSNull(), "steps": steps, "updatedAtUptime": started])
                return nil
            }

            let outcome = await Self.bounded(timeout: min(timeout, .seconds(remaining)), operation: operation)
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

        func pollState(
            _ name: String,
            performance: any BrowserPagePerformance,
            targetState: BrowserPageLifecycle.State,
            budgetSeconds: Int,
            sampleIntervalMilliseconds: Int = 100
        ) async -> PollResult? {
            await perform(name, timeout: .seconds(Int64(budgetSeconds + 1))) { [self] in
                let pollDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + Double(budgetSeconds))
                var count = 0
                var last = LifecycleSample.read(performance)
                while ProcessInfo.processInfo.systemUptime <= pollDeadline {
                    if Task.isCancelled { break }
                    last = LifecycleSample.read(performance)
                    count += 1
                    appendPoll(name, sample: last)
                    if last.state == targetState.rawValue {
                        return PollResult(reached: true, target: last.stateName, samples: count, last: last)
                    }
                    do { try await Task.sleep(for: .milliseconds(Int64(sampleIntervalMilliseconds))) }
                    catch { break }
                }
                return PollResult(reached: false, target: targetState == .frozen ? "frozen" : "running",
                                  samples: count, last: last)
            }
        }

        func pollZeroVetoMask(
            _ name: String,
            performance: any BrowserPagePerformance,
            budgetSeconds: Int
        ) async -> PollResult? {
            await perform(name, timeout: .seconds(Int64(budgetSeconds + 1))) { [self] in
                let pollDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + Double(budgetSeconds))
                var count = 0
                var last = LifecycleSample.read(performance)
                while ProcessInfo.processInfo.systemUptime <= pollDeadline {
                    if Task.isCancelled { break }
                    last = LifecycleSample.read(performance)
                    count += 1
                    appendPoll(name, sample: last)
                    if last.state == BrowserPageLifecycle.State.running.rawValue && last.mask == 0 {
                        return PollResult(reached: true, target: "running with zero veto mask", samples: count, last: last)
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { break }
                }
                return PollResult(reached: false, target: "running with zero veto mask", samples: count, last: last)
            }
        }

        func recordLifecycle(_ name: String, performance: any BrowserPagePerformance) -> LifecycleSample {
            let index = steps.count
            let started = ProcessInfo.processInfo.systemUptime
            steps.append(["name": name, "startUptime": started, "endUptime": NSNull(),
                          "result": "running", "status": "running"])
            publish(["activeStep": name, "steps": steps, "updatedAtUptime": started])
            let sample = LifecycleSample.read(performance)
            let ended = ProcessInfo.processInfo.systemUptime
            steps[index]["endUptime"] = ended
            steps[index]["result"] = sample.dictionary
            steps[index]["status"] = "completed"
            publish(["activeStep": NSNull(), "steps": steps, "updatedAtUptime": ended])
            return sample
        }

        private func appendPoll(_ name: String, sample: LifecycleSample) {
            guard let index = steps.lastIndex(where: { $0["name"] as? String == name }) else { return }
            var polls = steps[index]["polls"] as? [[String: Any]] ?? []
            polls.append(sample.dictionary)
            steps[index]["polls"] = polls
            let now = ProcessInfo.processInfo.systemUptime
            publish(["activeStep": name, "steps": steps, "updatedAtUptime": now])
        }

        private static func bounded<Value: Sendable>(
            timeout: Duration,
            operation: @escaping @MainActor @Sendable () async -> Value
        ) async -> BoundedOutcome<Value> {
            await withCheckedContinuation { continuation in
                let race = BoundedRace<Value>(continuation)
                let operationTask = Task { @MainActor in race.finish(.completed(await operation())) }
                let timeoutTask = Task { @MainActor in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    race.finish(.timedOut)
                }
                race.install(operation: operationTask, timeout: timeoutTask)
            }
        }
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

    private static func preferenceValue(engine: ChromiumBrowserEngine, profileID: ProfileID) -> Int? {
        guard let root = engine.diagnosticDataRoot(for: profileID) else { return nil }
        let path = root.appendingPathComponent("Preferences")
        guard let data = try? Data(contentsOf: path),
              let preference = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let network = preference["net"] as? [String: Any] else { return nil }
        return network["network_prediction_options"] as? Int
    }

    static func run(
        _ owner: OrbitWindowController,
        command: [String: String],
        progress: @escaping ([String: Any]) -> Void
    ) async -> [String: Any] {
        let trace = ProgressTrace(publish: progress)
        var result: [String: Any] = ["connectedPages": "unexercised in this focused round"]
        let text = command["url"] ?? ""
        let url = URL(string: text)
        let ports = command["ports"]?.split(separator: ",").compactMap { Int($0) } ?? []
        let onID = command["onProfileID"].flatMap { UUID(uuidString: $0) }.map { ProfileID($0) }
        let expectedOffID = command["offProfileID"].flatMap { UUID(uuidString: $0) }
        let admitted = await trace.perform("admission.synthetic_owner_and_loopback_fixture") {
            owns(owner) && url?.scheme == "http" && url?.host == "127.0.0.1"
                && ports.count == 7 && onID != nil && expectedOffID != nil
        } ?? false
        guard admitted, let url, let onID, let expectedOffID else {
            return ["ownershipOrFixtureRefused": true, "progress": trace.snapshot]
        }

        if owner.session.selectedSurface == nil || owner.session.snapshot?.selectedOccurrenceID == nil {
            owner.session.openTab(url: URL(string: "about:blank")!, activate: true)
            let anchorBarrier = await trace.perform("freeze.open_anchor_command_barrier") {
                await owner.session.waitForPendingCommands()
                return true
            } ?? false
            guard anchorBarrier else { return ["anchorCommandBarrierTimedOut": true, "progress": trace.snapshot] }
        }
        guard let liveAnchor = owner.session.selectedSurface,
              let liveAnchorOccurrence = owner.session.snapshot?.selectedOccurrenceID else {
            return ["missingAnchor": true, "progress": trace.snapshot]
        }
        guard liveAnchor.profileID.rawValue == expectedOffID else {
            return ["wrongSeededOffProfile": true,
                    "activeProfileID": liveAnchor.profileID.rawValue.uuidString,
                    "expectedOffProfileID": expectedOffID.uuidString,
                    "progress": trace.snapshot]
        }
        let anchorReady = await trace.perform("freeze.anchor_ready", timeout: .seconds(6)) {
            for _ in 0..<120 {
                if liveAnchor.isReady && !liveAnchor.navigationState.isLoading { return true }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            }
            return liveAnchor.isReady && !liveAnchor.navigationState.isLoading
        } ?? false
        guard anchorReady else { return ["anchorNotReady": true, "progress": trace.snapshot] }

        let preferenceKey = "net.network_prediction_options"
        let offPreference = await trace.perform("preconnect.read_disabled_preference") {
            preferenceValue(engine: owner.engine, profileID: liveAnchor.profileID) ?? -1
        }
        let onProfileReady = await trace.perform("preconnect.create_enabled_profile", timeout: .seconds(5)) {
            owner.engine.profile(for: onID)
            await owner.engine.profileReady(onID)
            return true
        } ?? false
        let onPreference = onProfileReady
            ? await trace.perform("preconnect.read_enabled_preference") {
                preferenceValue(engine: owner.engine, profileID: onID) ?? -1
            }
            : nil
        result["e4Preferences"] = [
            "key": preferenceKey,
            "disabledValue": 2,
            "enabledValue": 0,
            "offProfileID": liveAnchor.profileID.rawValue.uuidString,
            "offReadBack": offPreference.map { NSNumber(value: $0) as Any } ?? NSNull(),
            "onProfileID": onID.rawValue.uuidString,
            "onReadBack": onPreference.map { NSNumber(value: $0) as Any } ?? NSNull()
        ]

        let e4PreferencesProven = offPreference == 2 && onPreference == 0
        var e4OnAccepted = false
        var e4OffRejected = false
        if e4PreferencesProven {
            e4OnAccepted = await trace.perform("preconnect.enabled_positive_control", timeout: .seconds(3)) {
                owner.engine.preconnect(profileID: onID,
                    to: URL(string: "http://127.0.0.1:\(ports[0])/on")!, sockets: 1)
            } ?? false
            _ = await trace.perform("preconnect.enabled_socket_settle", timeout: .seconds(2)) {
                do { try await Task.sleep(for: .milliseconds(900)); return true }
                catch { return false }
            }
            e4OffRejected = await trace.perform("preconnect.disabled_profile_refusal", timeout: .seconds(3)) {
                !owner.engine.preconnect(profileID: liveAnchor.profileID,
                    to: URL(string: "http://127.0.0.1:\(ports[1])/off")!, sockets: 1)
            } ?? false
        }
        result["e4PreferenceOffGate"] = [
            "preferenceReadBackProven": e4PreferencesProven,
            "enabledPositiveControlAccepted": e4OnAccepted,
            "disabledPreconnectRejected": e4OffRejected,
            "enabledPort": ports[0],
            "disabledPort": ports[1]
        ]

        let originalOccurrences = Set(owner.session.snapshot?.tabs.map(\.occurrenceID) ?? [])
        owner.session.openTab(url: URL(string: "about:blank")!, activate: false)
        let backgroundCommandBarrier = await trace.perform("freeze.open_background_command_barrier") {
            await owner.session.waitForPendingCommands()
            return true
        } ?? false
        guard backgroundCommandBarrier else {
            result["backgroundCommandBarrierTimedOut"] = true
            result["progress"] = trace.snapshot
            return result
        }
        guard let targetRow = owner.session.snapshot?.tabs.first(where: { !originalOccurrences.contains($0.occurrenceID) }),
              let target = owner.session.surface(for: targetRow.occurrenceID) else {
            result["missingHostedBackgroundTab"] = true
            result["progress"] = trace.snapshot
            return result
        }
        let targetOccurrence = targetRow.occurrenceID
        owner.session.selectOccurrence(liveAnchorOccurrence)
        let selectionBarrier = await trace.perform("freeze.select_anchor_command_barrier") {
            await owner.session.waitForPendingCommands()
            return true
        } ?? false
        guard selectionBarrier else {
            owner.session.closeOccurrence(targetOccurrence)
            _ = await trace.perform("freeze.cleanup_close_after_anchor_selection_timeout") {
                await owner.session.waitForPendingCommands()
                return true
            }
            result["anchorSelectionTimedOut"] = true
            result["progress"] = trace.snapshot
            return result
        }

        let creationStateBeforeHostSignal = target.isBrowserCreated
        target.hostDidChange(hidden: true)
        let creationStateAfterEarlyHostSignal = target.isBrowserCreated
        let loaded = await trace.perform("freeze.load_never_shown_background_tab", timeout: .seconds(7)) {
            target.navigate(to: url)
            for _ in 0..<140 {
                if target.isReady && !target.navigationState.isLoading { return true }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            }
            return target.isReady && !target.navigationState.isLoading
        } ?? false
        guard loaded, let performance = target.pagePerformance else {
            owner.session.closeOccurrence(targetOccurrence)
            _ = await trace.perform("freeze.cleanup_close_unready_background_tab") {
                await owner.session.waitForPendingCommands()
                return true
            }
            result["backgroundPageNotReady"] = true
            result["progress"] = trace.snapshot
            return result
        }

        target.hostDidChange(hidden: true)
        let hostEvidence: [String: Any] = [
            "openedWithActivateFalse": true,
            "selectedOccurrenceStayedElsewhere": owner.session.snapshot?.selectedOccurrenceID == liveAnchorOccurrence,
            "targetIsVisibleOccurrence": owner.session.visibleOccurrenceIDs.contains(targetOccurrence),
            "hostViewHasWindow": target.hostView.window != nil,
            "hostViewHiddenOrAncestorHidden": target.hostView.isHiddenOrHasHiddenAncestor,
            "browserCreatedBeforeHostSignal": creationStateBeforeHostSignal,
            "browserCreatedAfterEarlyHostSignal": creationStateAfterEarlyHostSignal,
            "browserCreatedAfterLoad": target.isBrowserCreated,
            "hostHiddenSignalSentBeforeCreation": !creationStateBeforeHostSignal,
            "hostHiddenSignalSentAfterCreation": target.isBrowserCreated,
            "hostViewNeverAttachedToWindow": target.hostView.window == nil
        ]
        result["e1HostedBackgroundEvidence"] = hostEvidence

        let initialSample = trace.recordLifecycle("freeze.lifecycle_after_background_load", performance: performance)
        result["e1LifecycleBeforeVote"] = initialSample.dictionary
        let jslifecycle = "(()=>{const s={freeze:0,resume:0,ticks:0,ticksAtFreeze:-1,ticksAtResume:-1};document.addEventListener('freeze',()=>{s.freeze++;s.ticksAtFreeze=s.ticks});document.addEventListener('resume',()=>{s.resume++;s.ticksAtResume=s.ticks});s.timer=setInterval(()=>s.ticks++,100);window.__orbitR17Freeze=s;return {installed:true}})()"
        let observerReady = await trace.perform("freeze.install_events_and_suspended_work", timeout: .seconds(4)) {
            object(await evaluateJSON(target, jslifecycle))["installed"] as? Bool ?? false
        } ?? false
        _ = await trace.perform("freeze.timer_warmup", timeout: .seconds(2)) {
            do { try await Task.sleep(for: .milliseconds(1200)); return true }
            catch { return false }
        }
        let ticksBeforeJSON = await trace.perform("freeze.read_running_work_before_vote", timeout: .seconds(3)) {
            await evaluateJSON(target, "({ticks:window.__orbitR17Freeze?.ticks ?? -1})")
        } ?? ""
        let ticksBefore = object(ticksBeforeJSON)["ticks"] as? Int ?? -1

        var beforeVote = trace.recordLifecycle("freeze.lifecycle_immediately_before_vote", performance: performance)
        if (beforeVote.mask ?? 0) & (UInt64(1) << 21) != 0 {
            owner.session.selectOccurrence(liveAnchorOccurrence)
            _ = await trace.perform("freeze.reselect_anchor_after_mru_veto") {
                await owner.session.waitForPendingCommands()
                return true
            }
            if let settled = await trace.pollZeroVetoMask("freeze.clear_most_recently_used_veto",
                performance: performance, budgetSeconds: 3) {
                beforeVote = settled.last
            }
        }
        if beforeVote.mask != 0 {
            if let settled = await trace.pollZeroVetoMask("freeze.poll_for_zero_veto_mask",
                performance: performance, budgetSeconds: 3) {
                beforeVote = settled.last
            }
        }
        result["e1LifecycleImmediatelyBeforeVote"] = beforeVote.dictionary
        let noRuntimeBlockers = beforeVote.mask == 0 && beforeVote.state == BrowserPageLifecycle.State.running.rawValue
            && beforeVote.audible == false && beforeVote.playingMedia == false
            && beforeVote.audioContextRunning == false && beforeVote.webLock == false
            && beforeVote.indexedDBLock == false && beforeVote.webRTC == false && beforeVote.capturing == 0
        result["e1BaselineEligible"] = noRuntimeBlockers && observerReady && ticksBefore > 0

        var firstVoteAccepted = false
        var frozenPoll: PollResult?
        var resumePoll: PollResult?
        var voteRemovalAccepted = false
        var events: [String: Any] = [:]
        if noRuntimeBlockers && observerReady && ticksBefore > 0 {
            firstVoteAccepted = await trace.perform("freeze.add_vote_background_tab") {
                owner.engine.freezeTab(target, frozen: true)
            } ?? false
            result["e1LifecycleImmediatelyAfterVote"] = trace.recordLifecycle(
                "freeze.lifecycle_immediately_after_vote", performance: performance).dictionary
            if firstVoteAccepted {
                frozenPoll = await trace.pollState("freeze.poll_for_frozen", performance: performance,
                    targetState: .frozen, budgetSeconds: 20)
            }
            voteRemovalAccepted = await trace.perform("freeze.remove_vote_before_any_javascript") {
                owner.engine.freezeTab(target, frozen: false)
            } ?? false
            result["e1LifecycleImmediatelyAfterVoteRemoval"] = trace.recordLifecycle(
                "freeze.lifecycle_immediately_after_vote_removal", performance: performance).dictionary
            if frozenPoll?.reached == true {
                resumePoll = await trace.pollState("freeze.poll_for_running", performance: performance,
                    targetState: .running, budgetSeconds: 5)
            }
            let eventsJSON = await trace.perform("freeze.read_events_and_resumed_work", timeout: .seconds(3)) {
                await evaluateJSON(target, "({freeze:window.__orbitR17Freeze?.freeze ?? 0,resume:window.__orbitR17Freeze?.resume ?? 0,ticks:window.__orbitR17Freeze?.ticks ?? -1,ticksAtFreeze:window.__orbitR17Freeze?.ticksAtFreeze ?? -1,ticksAtResume:window.__orbitR17Freeze?.ticksAtResume ?? -1})")
            } ?? ""
            events = object(eventsJSON)
            _ = await trace.perform("freeze.resumed_work_settle", timeout: .seconds(2)) {
                do { try await Task.sleep(for: .milliseconds(800)); return true }
                catch { return false }
            }
            let settledEventsJSON = await trace.perform("freeze.read_settled_resume_work", timeout: .seconds(3)) {
                await evaluateJSON(target,
                    "({freeze:window.__orbitR17Freeze?.freeze ?? 0,resume:window.__orbitR17Freeze?.resume ?? 0,ticks:window.__orbitR17Freeze?.ticks ?? -1,ticksAtFreeze:window.__orbitR17Freeze?.ticksAtFreeze ?? -1,ticksAtResume:window.__orbitR17Freeze?.ticksAtResume ?? -1})")
            } ?? ""
            let settledEvents = object(settledEventsJSON)
            if !settledEvents.isEmpty { events = settledEvents }
        }
        let freezeEventCount = events["freeze"] as? Int ?? 0
        let resumeEventCount = events["resume"] as? Int ?? 0
        let ticksAtFreeze = events["ticksAtFreeze"] as? Int ?? -1
        let ticksAfterResume = events["ticks"] as? Int ?? -1
        let e1TransitionProven = noRuntimeBlockers && firstVoteAccepted && frozenPoll?.reached == true
            && voteRemovalAccepted && resumePoll?.reached == true && freezeEventCount > 0
            && resumeEventCount > 0 && ticksAtFreeze >= ticksBefore && ticksAfterResume > ticksAtFreeze
        result["e1FreezePoll"] = frozenPoll.map { $0.dictionary as Any } ?? NSNull()
        result["e1ResumePoll"] = resumePoll.map { $0.dictionary as Any } ?? NSNull()
        result["e1PageEventsAndWork"] = [
            "ticksBeforeVote": ticksBefore,
            "freezeEventCount": freezeEventCount,
            "resumeEventCount": resumeEventCount,
            "ticksAtFreeze": ticksAtFreeze,
            "ticksAtResume": events["ticksAtResume"] ?? NSNull(),
            "ticksAfterResume": ticksAfterResume,
            "transitionProven": e1TransitionProven
        ]

        var closeFrozen = false
        var secondVoteAccepted = false
        var secondVoteRemovalAccepted = false
        if e1TransitionProven {
            secondVoteAccepted = await trace.perform("freeze.add_vote_before_close") {
                owner.engine.freezeTab(target, frozen: true)
            } ?? false
            if secondVoteAccepted,
               let secondFrozen = await trace.pollState("freeze.poll_frozen_before_close",
                    performance: performance, targetState: .frozen, budgetSeconds: 4), secondFrozen.reached {
                secondVoteRemovalAccepted = await trace.perform("freeze.remove_vote_before_close") {
                    owner.engine.freezeTab(target, frozen: false)
                } ?? false
                let beforeClose = trace.recordLifecycle("freeze.lifecycle_after_vote_removal_before_close",
                    performance: performance)
                result["e1LifecycleAfterCloseVoteRemoval"] = beforeClose.dictionary
                if secondVoteRemovalAccepted && beforeClose.state == BrowserPageLifecycle.State.frozen.rawValue {
                    owner.session.closeOccurrence(targetOccurrence)
                    _ = await trace.perform("freeze.close_occurrence_while_lifecycle_still_frozen") {
                        await owner.session.waitForPendingCommands()
                        return true
                    }
                    closeFrozen = target.isDisposed && target.isTeardownComplete
                }
            }
        }
        if !target.isDisposed {
            _ = owner.engine.freezeTab(target, frozen: false)
            owner.session.closeOccurrence(targetOccurrence)
            _ = await trace.perform("freeze.cleanup_close_background_occurrence") {
                await owner.session.waitForPendingCommands()
                return true
            }
        }
        let e1Qualified = e1TransitionProven && closeFrozen
        result["e1CloseWhileFrozen"] = [
            "secondVoteAccepted": secondVoteAccepted,
            "secondVoteRemovalAccepted": secondVoteRemovalAccepted,
            "closedWhileFrozen": closeFrozen,
            "surfaceDisposed": target.isDisposed,
            "teardownComplete": target.isTeardownComplete
        ]
        result["e1RuntimeQualified"] = e1Qualified
        result["e1Cause"] = e1Qualified ? "qualified" :
            (beforeVote.mask != 0 ? "Chromium veto before vote: \(beforeVote.decodedReasons)" :
             (frozenPoll?.reached != true ? "vote accepted but lifecycle did not reach frozen" :
              (resumePoll?.reached != true ? "vote removed but lifecycle did not return to running" :
               "freeze/resume event or close-while-frozen evidence missing")))

        result["e4PreferenceCallsQualified"] = e4PreferencesProven && e4OnAccepted && e4OffRejected
        result["progress"] = trace.snapshot
        return result
    }
}
