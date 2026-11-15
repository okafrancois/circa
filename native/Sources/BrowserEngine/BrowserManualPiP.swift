import Foundation

/// Manual PiP owns no automatic-return session. The target is scoped to a document and an
/// isolated execution context; navigation or a replaced element invalidates the request.
/// The same isolated world drives the media element directly (`controlMedia`) for players the
/// engine leaves out of its media session, such as a muted tab's.
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
    private var world: (context: Int, generation: UInt64)?

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
              let context = await isolatedContext(document: document, fresh: true),
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

    /// The main frame's isolated world for `document`, created when missing, stale or `fresh`.
    private func isolatedContext(document: UInt64, fresh: Bool) async -> Int? {
        if !fresh, let world, world.generation == document { return world.context }
        guard let tree = await call("Page.getFrameTree"),
              let frame = (tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any],
              let frameID = frame["id"] as? String,
              let created = await call("Page.createIsolatedWorld", ["frameId": frameID, "worldName": "OrbitManualPiP"]),
              let context = created["executionContextId"] as? Int,
              generation() == document else { return nil }
        world = (context, document)
        return context
    }

    /// Plays, pauses or seeks the main frame's media element and returns its state afterwards.
    /// Retries once in a fresh isolated world when the cached one no longer answers.
    public func controlMedia(_ action: BrowserMediaAction, seconds: Double) async -> BrowserMediaElementState? {
        let name: String
        switch action {
        case .play: name = "play"
        case .pause: name = "pause"
        case .seek where seconds.isFinite: name = "seek"
        default: return nil
        }
        guard let document = generation() else { return nil }
        for attempt in 0..<2 {
            guard let context = await isolatedContext(document: document, fresh: attempt > 0) else { return nil }
            let result = await call("Runtime.evaluate", ["expression": "(\(Self.control))('\(name)', \(seconds))",
                "contextId": context, "returnByValue": true, "awaitPromise": true, "userGesture": true])
            guard generation() == document else { return nil }
            guard let result, result["exceptionDetails"] == nil else { world = nil; continue }
            guard let value = (result["result"] as? [String: Any])?["value"] as? [String: Any],
                  let paused = value["paused"] as? Bool else { return nil }
            return BrowserMediaElementState(paused: paused, position: value["position"] as? Double,
                duration: value["duration"] as? Double, playbackRate: value["rate"] as? Double)
        }
        return nil
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
    // Pause targets the element that plays; play and seek keep the element the card drove last,
    // so a pause from the card resumes the same player.
    package static let control = #"""
    async (action, seconds) => {
      const key = 'orbitMediaControlTarget';
      const history = globalThis.orbitManualPiPHistory ??= new WeakMap();
      const media = [...document.querySelectorAll('video, audio')].filter(m => m.readyState >= 1);
      for (const m of media) {
        if (!history.has(m)) {
          history.set(m, 0);
          m.addEventListener('play', () => history.set(m, performance.now()));
        }
      }
      const previous = globalThis[key];
      const playing = m => Number(!m.paused && !m.ended);
      const chosen = m => Number(m === previous);
      media.sort((a, b) => action === 'pause'
        ? playing(b) - playing(a) || chosen(b) - chosen(a) || history.get(b) - history.get(a)
        : chosen(b) - chosen(a) || playing(b) - playing(a) || history.get(b) - history.get(a));
      const element = media[0];
      if (!element) { delete globalThis[key]; return null; }
      globalThis[key] = element;
      try {
        if (action === 'play') await element.play();
        else if (action === 'pause') element.pause();
        else if (Number.isFinite(element.duration)) element.currentTime = Math.min(element.duration, Math.max(0, seconds));
        else return null;
      } catch (_) { return null; }
      const finite = v => Number.isFinite(v) ? v : null;
      return { paused: element.paused, position: finite(element.currentTime),
               duration: finite(element.duration), rate: finite(element.playbackRate) };
    }
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
