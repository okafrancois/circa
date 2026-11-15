import Foundation

/// Manual PiP owns no automatic-return session. The target is scoped to a document and an
/// isolated execution context; navigation or a replaced element invalidates the request.
@MainActor
public final class BrowserManualPiP {
    public enum State: Equatable, Sendable {
        case unavailable, ready, requesting, active, failed
    }
    public enum Failure: Equatable, Sendable { case rejected, timeout, transport }
    public private(set) var failure: Failure = .rejected
    public typealias Transport = @MainActor (String, String) async -> (Bool, Data)
    public private(set) var state: State = .unavailable { didSet { if oldValue != state { onChange?() } } }
    public var onChange: (() -> Void)?
    private let transport: Transport
    private let generation: @MainActor () -> UInt64?
    private let exit: @MainActor () -> Void
    private var target: (context: Int, generation: UInt64)?
    private var querying = false
    private var revision = 0

    public init(transport: @escaping Transport, generation: @escaping @MainActor () -> UInt64?,
                exit: @escaping @MainActor () -> Void) {
        self.transport = transport; self.generation = generation; self.exit = exit
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return nil }
        let (ok, response) = await transport(method, String(decoding: data, as: UTF8.self))
        return ok ? (try? JSONSerialization.jsonObject(with: response) as? [String: Any]) : nil
    }

    public func refresh() async {
        guard !querying, state != .requesting, state != .active else { return }
        querying = true
        defer { querying = false }
        let revision = self.revision
        guard let document = generation(),
              let tree = await call("Page.getFrameTree"),
              let frame = (tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any],
              let frameID = frame["id"] as? String,
              let world = await call("Page.createIsolatedWorld", ["frameId": frameID, "worldName": "OrbitManualPiP"]),
              let context = world["executionContextId"] as? Int,
              let result = await call("Runtime.evaluate", ["expression": Self.query, "contextId": context, "returnByValue": true]),
              generation() == document, revision == self.revision,
              result["exceptionDetails"] == nil,
              (result["result"] as? [String: Any])?["value"] as? Bool == true else {
            if revision == self.revision { target = nil; state = .unavailable }
            return
        }
        target = (context, document)
        if state != .failed { state = .ready }
    }

    public func toggle() async {
        if state == .active { exit(); return }
        guard state == .ready || state == .failed, let target, generation() == target.generation else {
            self.target = nil; state = .unavailable; return
        }
        revision += 1
        let request = revision
        state = .requesting
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, request == revision, state == .requesting else { return }
            failure = .timeout
            state = .failed
        }
        defer { timeout.cancel() }
        let result = await call("Runtime.evaluate", ["expression": Self.enter, "contextId": target.context,
            "returnByValue": true, "awaitPromise": true, "userGesture": true])
        guard request == revision else { return }
        guard generation() == target.generation else { self.target = nil; state = .unavailable; return }
        guard result?["exceptionDetails"] == nil,
              (result?["result"] as? [String: Any])?["value"] as? Bool == true else {
            if state != .active { failure = result == nil ? .transport : .rejected; state = .failed }
            return
        }
        // Only the native lifecycle is an acknowledgement. Evaluation success alone is not.
        await timeout.value
    }

    public func acknowledge(active: Bool) {
        if active { state = .active }
        else if state == .active { revision += 1; target = nil; state = .unavailable }
    }

    // Keep the chosen element, rather than selecting a different player between query and entry.
    // Main-frame videos only: cross-origin iframe eligibility is intentionally unavailable.
    package static let query = #"""
    (() => {
      const key = 'orbitManualPiPTarget';
      if (!document.pictureInPictureEnabled) { delete globalThis[key]; return false; }
      const videos = [...document.querySelectorAll('video')].filter(v =>
        v.readyState >= 1 && !v.disablePictureInPicture && v.videoWidth > 0);
      const previous = globalThis[key];
      const history = globalThis.orbitManualPiPHistory ??= new WeakMap();
      for (const video of videos) {
        if (!history.has(video)) {
          history.set(video, 0);
          video.addEventListener('play', () => history.set(video, performance.now()));
        }
      }
      videos.sort((a,b) => Number(!b.paused && !b.ended) - Number(!a.paused && !a.ended) ||
        history.get(b) - history.get(a) || Number(b === previous) - Number(a === previous) || b.currentTime - a.currentTime);
      globalThis[key] = videos[0];
      return !!videos[0];
    })()
    """#
    package static let enter = #"""
    (async () => {
      const video = globalThis.orbitManualPiPTarget;
      if (!document.pictureInPictureEnabled || !video?.isConnected || video.readyState < 1 ||
          video.disablePictureInPicture) return false;
      try { await video.requestPictureInPicture(); return document.pictureInPictureElement === video; }
      catch (_) { return false; }
    })()
    """#
}
