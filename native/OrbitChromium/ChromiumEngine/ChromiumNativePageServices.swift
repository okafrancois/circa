import BrowserEngine
import Foundation
import OrbitChromiumBridge

@MainActor
final class ChromiumNativePageServices: BrowserNativePageServices {
    let token: UInt64
    private var closed = false
    private var securityListeners: [UUID: AsyncStream<BrowserPageSecurityState>.Continuation] = [:]
    private var fullscreenListeners: [UUID: AsyncStream<BrowserPageFullscreenChange>.Continuation] = [:]
    private var mediaListeners: [UUID: AsyncStream<BrowserMediaSessionState>.Continuation] = [:]
    init(token: UInt64) { self.token = token }

    var supportsTaskManager: Bool { !closed && ACREngineDiagnosticCapabilities() & 1 != 0 }
    var supportsTracing: Bool { !closed && ACREngineDiagnosticCapabilities() & 2 != 0 }
    func openTaskManager() -> Bool { supportsTaskManager && ACRTaskManager(token) == 1 }
    func beginTracing(categories: String) async -> Bool {
        guard supportsTracing, !categories.utf8.contains(0) else { return false }
        return await traceOperation { callback, context in
            ACRTraceBegin(token, categories, callback, context)
        }
    }
    func endTracing(to file: URL) async -> Bool {
        guard supportsTracing, file.isFileURL, !file.path.utf8.contains(0) else { return false }
        return await traceOperation { callback, context in
            ACRTraceEnd(token, file.path, callback, context)
        }
    }
    private final class TraceReply {
        let continuation: CheckedContinuation<Bool, Never>
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    }
    private func traceOperation(_ call: (orbit_trace_callback_t?, UnsafeMutableRawPointer?) -> Int32) async -> Bool {
        await withCheckedContinuation { continuation in
            let context = Unmanaged.passRetained(TraceReply(continuation)).toOpaque()
            let accepted = call({ context, success, _ in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<TraceReply>.fromOpaque(context).takeRetainedValue().continuation.resume(returning: success == 1)
                }
            }, context)
            if accepted != 1 {
                Unmanaged<TraceReply>.fromOpaque(context).takeRetainedValue().continuation.resume(returning: false)
            }
        }
    }

    func securityState() -> BrowserPageSecurityState? { decodeRead(0) }
    func navigationHistory() -> BrowserNavigationHistory? { decodeRead(2) }
    func mediaState() -> BrowserMediaSessionState? { decodeRead(3) }
    func committedURL() -> URL? {
        guard let data = read(1), let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return URL(string: text)
    }
    func securityDisplay(for url: URL, scheme: BrowserSecuritySchemeDisplay) -> String? {
        guard !closed else { return nil }
        return url.absoluteString.withCString { text in
            copyText { ACRSecurityDisplay(text, scheme.rawValue, $0, $1) }
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }
    func goToEntry(index: Int) -> Bool {
        guard !closed, let nativeIndex = Int32(exactly: index) else { return false }
        return ACRNavigationGoIndex(token, nativeIndex) == 1
    }
    func mediaAction(_ action: BrowserMediaAction, seconds: Double) -> Bool {
        guard !closed, seconds.isFinite, seconds >= 0 else { return false }
        return ACRMediaAction(token, action.rawValue, seconds) == 1
    }
    func securityChanges() -> AsyncStream<BrowserPageSecurityState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            guard !closed else { continuation.finish(); return }
            if securityListeners.isEmpty {
                guard ACRSecurityObserve(token, { ctx, text, count in
                    guard let ctx, let text else { return }
                    MainActor.assumeIsolated {
                        let owner = Unmanaged<ChromiumNativePageServices>.fromOpaque(ctx).takeUnretainedValue()
                        guard let value = try? JSONDecoder().decode(BrowserPageSecurityState.self, from: Data(bytes: text, count: Int(count))) else { return }
                        for listener in owner.securityListeners.values { listener.yield(value) }
                    }
                }, Unmanaged.passUnretained(self).toOpaque()) == 1 else { continuation.finish(); return }
            }
            securityListeners[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.removeSecurity(id) } }
            if let state = securityState() { continuation.yield(state) }
        }
    }
    func fullscreenChanges() -> AsyncStream<BrowserPageFullscreenChange> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            guard !closed else { continuation.finish(); return }
            if fullscreenListeners.isEmpty {
                guard ACRFullscreenObserve(token, { ctx, entered, origin in
                    guard let ctx, let origin else { return }
                    MainActor.assumeIsolated {
                        let owner = Unmanaged<ChromiumNativePageServices>.fromOpaque(ctx).takeUnretainedValue()
                        let change = BrowserPageFullscreenChange(entered: entered != 0, origin: String(cString: origin))
                        for listener in owner.fullscreenListeners.values { listener.yield(change) }
                    }
                }, Unmanaged.passUnretained(self).toOpaque()) == 1 else { continuation.finish(); return }
            }
            fullscreenListeners[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.removeFullscreen(id) } }
        }
    }
    func mediaChanges() -> AsyncStream<BrowserMediaSessionState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            guard !closed else { continuation.finish(); return }
            if mediaListeners.isEmpty {
                guard ACRMediaObserve(token, { ctx, text, count in
                    guard let ctx, let text else { return }
                    MainActor.assumeIsolated {
                        let owner = Unmanaged<ChromiumNativePageServices>.fromOpaque(ctx).takeUnretainedValue()
                        guard let value = try? JSONDecoder().decode(BrowserMediaSessionState.self, from: Data(bytes: text, count: Int(count))) else { return }
                        for listener in owner.mediaListeners.values { listener.yield(value) }
                    }
                }, Unmanaged.passUnretained(self).toOpaque()) == 1 else { continuation.finish(); return }
            }
            mediaListeners[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.removeMedia(id) } }
            if let state = mediaState() { continuation.yield(state) }
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        ACRNativePageServicesClosing(token)
        let security = securityListeners; securityListeners.removeAll()
        let fullscreen = fullscreenListeners; fullscreenListeners.removeAll()
        let media = mediaListeners; mediaListeners.removeAll()
        for item in security.values { item.finish() }
        for item in fullscreen.values { item.finish() }
        for item in media.values { item.finish() }
    }
    private func removeSecurity(_ id: UUID) {
        securityListeners[id] = nil
        if securityListeners.isEmpty { _ = ACRSecurityObserve(token, nil, nil) }
    }
    private func removeFullscreen(_ id: UUID) {
        fullscreenListeners[id] = nil
        if fullscreenListeners.isEmpty { _ = ACRFullscreenObserve(token, nil, nil) }
    }
    private func removeMedia(_ id: UUID) {
        mediaListeners[id] = nil
        if mediaListeners.isEmpty { _ = ACRMediaObserve(token, nil, nil) }
    }
    private func decodeRead<T: Decodable>(_ kind: Int32) -> T? {
        read(kind).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func read(_ kind: Int32) -> Data? {
        guard !closed else { return nil }
        return copyText { ACRNativePageRead(token, kind, $0, $1) }
    }
    private func copyText(_ call: (UnsafeMutablePointer<CChar>?, UInt32) -> Int32) -> Data? {
        let size = call(nil, 0)
        guard size >= 0, size < 1_048_576 else { return nil }
        // Live position timestamps can change JSON length between these two calls.
        // Capacity, rather than equality with the earlier size, establishes a full write.
        var capacity = min(1_048_576, Int(size) + 1025)
        for _ in 0..<3 {
            var bytes = [CChar](repeating: 0, count: capacity)
            let written = call(&bytes, UInt32(capacity))
            guard written >= 0, written < 1_048_576 else { return nil }
            if Int(written) < capacity { return Data(bytes: bytes, count: Int(written)) }
            capacity = min(1_048_576, Int(written) + 1025)
        }
        return nil
    }
}
