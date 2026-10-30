import AppKit
import BrowserEngine
import ChromiumEngine

/// Confined native-engine qualification endpoint. No installed or personal bundle can enable it.
@MainActor
enum OrbitEnginePerformanceProbe {
    private static var victim: ChromiumSurface?
    private static var media: ChromiumSurface?
    private static var events: [BrowserPageLifecycleChange] = []
    private static var subscription: Task<Void, Never>?
    private static var hiddenAt: TimeInterval = 0

    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard ["lab.orbit.orbit.engine-r11", "lab.orbit.orbit.engine-r12", "lab.orbit.orbit.engine-r13", "lab.orbit.orbit.engine-r14"].contains(Bundle.main.bundleIdentifier ?? ""),
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              let window = owner.window, NSApp.windows.contains(where: { $0 === window }) else { return false }
        // Hidden qualification performs no OS input; the exact window object remains process-owned.
        if !window.isVisible { return true }
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }
    private static func loaded(_ surface: ChromiumSurface) async {
        for _ in 0..<200 {
            if surface.isReady && !surface.navigationState.isLoading { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        guard owns(owner) else { return ["ownershipRefused": true] }
        let step = command["step"] ?? "core"
        if step == "pressure" {
            guard let victim, let api = victim.pagePerformance,
                  ProcessInfo.processInfo.systemUptime - hiddenAt >= 601 else { return ["notAged": true] }
            let before = api.lifecycle()
            let result = await victim.devToolsCall("Memory.simulatePressureNotification", params: #"{"level":"critical"}"#)
            try? await Task.sleep(for: .seconds(2))
            return ["pressureAccepted": result.0, "discarded": api.lifecycle()?.state == .discarded,
                    "nativeNotification": events.contains { $0.event == .discarded && $0.initiator == .nativePolicy },
                    "beforeMask": before?.cannotDiscardMask ?? UInt64.max,
                    "events": events.map { ["event": $0.event.rawValue, "initiator": $0.initiator.rawValue] }]
        }
        if step == "show" { owner.window?.makeKeyAndOrderFront(nil); return ["shown": true] }
        if step == "pip-status", let media {
            var result = pipWindows()
            if let state = media.pagePerformance?.lifecycle() {
                result["lifecycle"] = ["video": state.playingVideo, "media": state.playingMedia, "pip": state.pictureInPicture, "audible": state.audible]
            }
            let (ok, bytes) = await media.devToolsCall("Runtime.evaluate", params: #"{"expression":"({paused:document.querySelector('video').paused,time:document.querySelector('video').currentTime,pip:!!document.pictureInPictureElement})","returnByValue":true}"#, timeout: .seconds(1))
            if ok, let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               let resultValue = json["result"] as? [String: Any], let value = resultValue["value"] as? [String: Any] { result["playback"] = value }
            return result
        }
        if step == "pip-return" || step == "pip-manual", let media,
           let occurrence = owner.session.occurrenceID(for: media) {
            owner.session.selectOccurrence(occurrence)
            await owner.session.waitForQueuedCommands()
            try? await Task.sleep(for: .milliseconds(600))
            if step == "pip-manual" {
                _ = await OrbitPerformanceProbe.evaluate(media, "(()=>{document.querySelector('video').requestPictureInPicture();return {requested:true}})()")
                try? await Task.sleep(for: .milliseconds(600))
            }
            return pipWindows()
        }
        guard ["core", "prepare", "pip"].contains(step) else { return ["unavailable": true] }
        guard let text = command["url"], let url = URL(string: text), url.host == "127.0.0.1", url.scheme == "http" else { return ["fixtureRefused": true] }
        owner.session.openTab(url: url)
        await owner.session.waitForQueuedCommands()
        guard let tab = owner.session.selectedSurface else { return ["missingSurface": true] }
        await loaded(tab)
        guard let api = tab.pagePerformance else { return ["apiUnavailable": true] }
        if step == "pip" {
            media = tab
            if let settings = owner.settingsPreferences?.runtime {
                try? await settings.store.setAutomaticPictureInPicture(true)
                await settings.refresh()
            }
            _ = await OrbitPerformanceProbe.evaluate(tab, "(()=>{let v=document.querySelector('video');v.muted=true;v.play();return {playing:true}})()")
            try? await Task.sleep(for: .seconds(10))
            owner.session.openTab(url: url.appendingPathComponent("pip-background"))
            await owner.session.waitForQueuedCommands()
            try? await Task.sleep(for: .seconds(1))
            return pipWindows()
        }
        var checks: [String: Any] = [:]
        if step == "prepare" {
            victim = tab; events = []
            subscription?.cancel()
            let stream = api.changes()
            subscription = Task { for await event in stream { events.append(event) } }
            owner.session.openTab(url: url.appendingPathComponent("selected"))
            await owner.session.waitForQueuedCommands()
            hiddenAt = ProcessInfo.processInfo.systemUptime
            owner.window?.orderOut(nil)
            return ["prepared": true, "hiddenAt": hiddenAt, "pid": getpid()]
        }
        if ["lab.orbit.orbit.engine-r12", "lab.orbit.orbit.engine-r13", "lab.orbit.orbit.engine-r14"].contains(Bundle.main.bundleIdentifier ?? "") {
            let dump = await api.memoryDump()
            checks["memoryDumpStatus"] = dump.status.rawValue
            checks["memoryDumpOutcome"] = dump.outcome ?? -1
            checks["memoryDump"] = dump.status == .complete && dump.processes.contains { $0.pid == getpid() && $0.kind == .browser }
                && dump.processes.contains { $0.kind == .renderer && $0.pid > 0 }
            checks["memoryAllocators"] = dump.processes.contains { $0.allocators["malloc"] != nil }
                && dump.processes.contains { $0.allocators["v8"] != nil }
                && dump.processes.allSatisfy { $0.privateFootprintKB != nil }
            checks["memoryDumpPayload"] = (try? JSONEncoder().encode(dump.processes)).map { String(decoding: $0, as: UTF8.self) } ?? ""

        }
        checks["lifecycle"] = api.lifecycle().map { $0.rendererPID > 0 && $0.documentID > 0 && $0.state == .running } ?? false
        let changing = Task { await api.activationFrame(activationID: 8) }
        await Task.yield()
        tab.navigate(to: url.appendingPathComponent("document-change"))
        checks["documentChanged"] = await changing.value.status == .documentChanged
        await loaded(tab)
        var editedChange = false
        let flagsStream = api.changes()
        let flagsObserver = Task { for await change in flagsStream {
            if change.state?.hadUserEdits == true { editedChange = true }
        } }
        _ = await OrbitPerformanceProbe.evaluate(tab, "(()=>{document.querySelector('#edit').focus();return {focused:true}})()")
        if owns(owner) { _ = await tab.devToolsCall("Input.insertText", params: #"{"text":"Synthetic edit"}"#) }
        try? await Task.sleep(for: .milliseconds(200))
        checks["trustedEdits"] = api.lifecycle()?.hadUserEdits == true && editedChange
        _ = await OrbitPerformanceProbe.evaluate(tab, "(()=>{document.querySelector('#input').focus();return {focused:true}})()")
        if owns(owner) { _ = await tab.devToolsCall("Input.insertText", params: #"{"text":"Synthetic input"}"#) }
        _ = await OrbitPerformanceProbe.evaluate(tab, "(()=>{navigator.locks.request('synthetic-lock',()=>new Promise(r=>globalThis.releaseLock=r));return {requested:true}})()")
        try? await Task.sleep(for: .milliseconds(200))
        checks["formInteraction"] = api.lifecycle()?.hadFormInteraction == true
        checks["webLock"] = api.lifecycle()?.webLock == true
        // Release the fixture lock before navigating: cached documents may retain it,
        // and the shell correctly protects tabs with an outstanding lock.
        _ = await OrbitPerformanceProbe.evaluate(tab, "(()=>{releaseLock();return {released:true}})()")
        try? await Task.sleep(for: .milliseconds(200))
        flagsObserver.cancel()
        tab.navigate(to: url.appendingPathComponent("fresh-document"))
        await loaded(tab)
        checks["editsResetOnNavigation"] = api.lifecycle()?.hadUserEdits == false
        let thumb = await api.capture(.init(outputWidth: 200, outputHeight: 120))
        checks["captureSizeAndMemory"] = thumb.status == .captured && thumb.width == 200 && thumb.height == 120 && thumb.pixels.count == 96000
        var request = BrowserNativeCaptureRequest(outputWidth: 64, outputHeight: 1)
        request.width = 500; request.height = 2
        let strip = await api.capture(request)
        checks["stripSizeAndMemory"] = strip.status == .captured && strip.pixels.count == 256
        checks["captureStatus"] = thumb.status.rawValue
        let frame = await api.activationFrame(activationID: 1)
        checks["submitted"] = frame.status == .submitted && frame.documentID == api.lifecycle()?.documentID && frame.submittedTicksUS > 0
        owner.session.openTab(url: url.appendingPathComponent("background"))
        await owner.session.waitForQueuedCommands()
        try? await Task.sleep(for: .milliseconds(300))
        let hidden = await api.activationFrame(activationID: 2)
        checks["hidden"] = hidden.status == .hidden
        checks["hiddenStatus"] = hidden.status.rawValue
        checks["hiddenCapture"] = await api.capture(.init(outputWidth: 64, outputHeight: 1)).status == .unavailable
        let changes = api.changes()
        var discarded = false
        let observer = Task { for await event in changes { if event.event == .discarded && event.initiator == .embedder { discarded = true } } }
        // The surface API keeps the existing conservative shell admission; the native API is proved separately.
        let oldEngineEvent = tab.onEngineEvent
        tab.onEngineEvent = { name, fields in
            oldEngineEvent?(name, fields)
            if name == "suspension-refused" { checks["discardRefusal"] = fields["reason"] ?? "unknown" }
        }
        if let state = api.lifecycle() {
            checks["discardNativeState"] = ["mask": state.cannotDiscardMask, "webLock": state.webLock,
                                            "userEdits": state.hadUserEdits, "form": state.hadFormInteraction] as [String: Any]
        }
        let suspended = await tab.captureStateForSuspension()
        tab.onEngineEvent = oldEngineEvent
        if suspended != nil { checks["discardAccepted"] = owner.session.suspendSurface(tab) }
        try? await Task.sleep(for: .milliseconds(300))
        checks["embedderDiscard"] = discarded && api.lifecycle()?.state == .discarded
        observer.cancel()
        // Exercise activation cancellation on an independently attached page.
        owner.session.openTab(url: url.appendingPathComponent("activation"))
        await owner.session.waitForQueuedCommands()
        guard let activationTab = owner.session.selectedSurface,
              let activationAPI = activationTab.pagePerformance else { return checks }
        await loaded(activationTab)
        var activationVisible = false
        for attempt in 0..<20 {
            let frame = await activationAPI.activationFrame(activationID: UInt64(100 + attempt))
            if frame.status == .submitted { activationVisible = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        checks["activationVisible"] = activationVisible
        // A blocked renderer makes cancellation/status ordering deterministic.
        let hang = Task { await activationTab.devToolsCall("Runtime.evaluate", params: #"{"expression":"while(true){}"}"#, timeout: .milliseconds(250)) }
        try? await Task.sleep(for: .milliseconds(100))
        checks["timedOut"] = await activationAPI.activationFrame(activationID: 3).status == .timedOut
        let older = Task { await activationAPI.activationFrame(activationID: 4) }
        await Task.yield()
        let newer = await activationAPI.activationFrame(activationID: 5)
        checks["superseded"] = await older.value.status == .documentChanged && newer.status == .timedOut
        let closing = Task { await activationAPI.activationFrame(activationID: 6) }
        await Task.yield()
        _ = owner.session.closeOwnedSurface(activationTab)
        let closed = await closing.value
        checks["closed"] = closed.status == .closed
        checks["closedStatus"] = closed.status.rawValue
        _ = await hang.value
        return checks
    }
    private static func pipWindows() -> [String: Any] {
        ["windows": NSApp.windows.map { window in
            ["number": window.windowNumber, "class": String(describing: type(of: window)),
             "level": window.level.rawValue, "visible": window.isVisible,
             "frame": NSStringFromRect(window.frame)] as [String: Any]
        }]
    }

}
