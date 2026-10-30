import BrowserEngine
import Foundation
import OrbitChromiumBridge

@MainActor
final class ChromiumPagePerformance: BrowserPagePerformance {
    let token: UInt64
    private var closed = false
    private var observing = false
    private var listeners: [UUID: AsyncStream<BrowserPageLifecycleChange>.Continuation] = [:]
    init(token: UInt64) { self.token = token }

    func memoryDump() async -> BrowserMemoryDump {
        guard !closed else { return .init(status: .unavailable) }
        return await withCheckedContinuation { continuation in
            let context = Unmanaged.passRetained(PerformanceReply(continuation)).toOpaque()
            if ACRMemoryDump({ ctx, status, json, length in
                guard let ctx else { return }
                MainActor.assumeIsolated {
                    let reply = Unmanaged<PerformanceReply<BrowserMemoryDump>>.fromOpaque(ctx).takeRetainedValue()
                    let bytes = json.map { Data(bytes: $0, count: Int(length)) } ?? Data()
                    reply.continuation.resume(returning: BrowserMemoryDump.decode(bytes, status: status))
                }
            }, context) != 1 {
                Unmanaged<PerformanceReply<BrowserMemoryDump>>.fromOpaque(context).takeRetainedValue().continuation.resume(returning: .init(status: .unavailable))
            }
        }
    }
    func lifecycle() -> BrowserPageLifecycle? {
        guard !closed else { return nil }
        var state = orbit_page_lifecycle_t()
        state.struct_size = UInt32(MemoryLayout.size(ofValue: state))
        guard ACRPageLifecycle(token, &state) == 1 else { return nil }
        return Self.decode(state)
    }
    func changes() -> AsyncStream<BrowserPageLifecycleChange> {
        let id = UUID()
        return AsyncStream { continuation in
            guard !closed else { continuation.finish(); return }
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[id] = nil }
            }
            if !observing {
                observing = ACRPageLifecycleObserve(token, { context, event, initiator, state in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        let owner = Unmanaged<ChromiumPagePerformance>.fromOpaque(context).takeUnretainedValue()
                        let change = BrowserPageLifecycleChange(
                            event: .init(rawValue: event) ?? .changed,
                            initiator: .init(rawValue: initiator) ?? .none,
                            state: state.map { ChromiumPagePerformance.decode($0.pointee) })
                        for listener in owner.listeners.values { listener.yield(change) }
                        if event == 3 { owner.close() }
                    }
                }, Unmanaged.passUnretained(self).toOpaque()) == 1
                if !observing { close(); return }
            }
            if let state = lifecycle() { continuation.yield(.init(event: .changed, state: state)) }
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        ACRPagePerformanceClosing(token)
        if observing { _ = ACRPageLifecycleObserve(token, nil, nil) }
        observing = false
        let current = listeners; listeners.removeAll()
        for listener in current.values { listener.finish() }
    }
    func capture(_ request: BrowserNativeCaptureRequest) async -> BrowserNativeCapture {
        guard !closed else { return .init(status: .closed) }
        return await withCheckedContinuation { continuation in
            let context = Unmanaged.passRetained(PerformanceReply(continuation)).toOpaque()
            let rect = orbit_capture_rect_t(x: request.x, y: request.y, width: request.width, height: request.height)
            let accepted = ACRCaptureView(token, rect, request.outputWidth, request.outputHeight, request.timeoutMS, { ctx, status, w, h, stride, pixels, space in
                guard let ctx else { return }
                MainActor.assumeIsolated {
                    let reply = Unmanaged<PerformanceReply<BrowserNativeCapture>>.fromOpaque(ctx).takeRetainedValue()
                    let valid = status == 1 && space == 1 && w > 0 && h > 0 && w <= 4096 && h <= 4096 && stride == UInt32(w) * 4 && pixels != nil
                    reply.continuation.resume(returning: .init(
                        status: valid ? .captured : (BrowserNativeCapture.Status(rawValue: status) == .captured ? .unavailable : BrowserNativeCapture.Status(rawValue: status) ?? .unavailable),
                        width: valid ? w : 0, height: valid ? h : 0, rowBytes: valid ? stride : 0,
                        pixels: valid ? Data(bytes: pixels!, count: Int(stride) * Int(h)) : Data()))
                }
            }, context)
            if accepted != 1 {
                Unmanaged<PerformanceReply<BrowserNativeCapture>>.fromOpaque(context).takeRetainedValue().continuation.resume(returning: .init(status: .unavailable))
            }
        }
    }
    func activationFrame(activationID: UInt64) async -> BrowserActivationFrame {
        guard !closed else { return .init(browserID: -1, activationID: activationID, documentID: 0, status: .closed) }
        return await withCheckedContinuation { continuation in
            let context = Unmanaged.passRetained(PerformanceReply(continuation)).toOpaque()
            if ACRActivationFrame(token, activationID, { ctx, browser, activation, document, status, ticks in
                guard let ctx else { return }
                MainActor.assumeIsolated {
                    Unmanaged<PerformanceReply<BrowserActivationFrame>>.fromOpaque(ctx).takeRetainedValue().continuation.resume(returning: .init(
                        browserID: browser, activationID: activation, documentID: document,
                        status: .init(rawValue: status) ?? .closed, submittedTicksUS: ticks))
                }
            }, context) != 1 {
                Unmanaged<PerformanceReply<BrowserActivationFrame>>.fromOpaque(context).takeRetainedValue().continuation.resume(returning: .init(browserID: -1, activationID: activationID, documentID: 0, status: .closed))
            }
        }
    }
    private static func decode(_ s: orbit_page_lifecycle_t) -> BrowserPageLifecycle {
        var state = BrowserPageLifecycle()
        state.playingMedia = s.playing_media != 0; state.playingVideo = s.playing_video != 0
        state.audioContextRunning = s.audio_context_running != 0; state.audible = s.audible != 0
        state.pictureInPicture = s.pip != 0; state.capturing = s.capturing
        state.hadFormInteraction = s.had_form_interaction != 0; state.hadUserEdits = s.had_user_edits != 0
        state.webLock = s.web_lock != 0; state.indexedDBLock = s.idb_lock != 0; state.webRTC = s.webrtc != 0
        state.state = .init(rawValue: s.lifecycle) ?? .running
        state.cannotDiscardMask = s.cannot_discard_mask; state.footprintKB = s.footprint_kb
        state.rendererPID = s.renderer_pid; state.documentID = s.document_id
        return state
    }
}

@MainActor
private final class PerformanceReply<Value: Sendable> {
    let continuation: CheckedContinuation<Value, Never>
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
}
