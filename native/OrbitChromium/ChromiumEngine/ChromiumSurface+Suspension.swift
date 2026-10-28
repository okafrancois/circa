import BrowserEngine
import BrowserShell
import OrbitChromiumBridge
import Foundation

extension ChromiumSurface {
    public var allowsSuspension: Bool { canSuspendDocument }
    /// Checks every frame, including cross-origin frames, in a DevTools isolated world. Page
    /// scripts cannot replace this world's DOM builtins or erase its edit listener. Values and
    /// text are compared inside the renderer; only a boolean and scroll coordinates return.
    public func captureStateForSuspension() async -> BrowserSuspensionState? {
        guard canSuspendDocument, let url = navigationState.committedURL,
              ["http", "https"].contains(url.scheme) else { return refuseSuspension("native-protection") }
        let generation = documentGeneration
        let (ok, data) = await devToolsCall("Page.getFrameTree")
        guard ok, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = json["frameTree"] as? [String: Any] else { return refuseSuspension("frame-tree") }
        func frames(_ tree: [String: Any]) -> [String] {
            guard let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String else { return [] }
            return [id] + (tree["childFrames"] as? [[String: Any]] ?? []).flatMap(frames)
        }
        let ids = frames(tree)
        guard !ids.isEmpty else { return refuseSuspension("no-frames") }
        var scroll: (Double, Double) = (0, 0)
        for (index, id) in ids.enumerated() {
            guard let context = await suspensionWorld(frameID: id) else { return refuseSuspension("isolated-world") }
            guard let state = await evaluateSuspension(Self.suspensionCheck, context: context) else { return refuseSuspension("document-check") }
            if index == 0, state["documentURL"] as? String != url.absoluteString { return refuseSuspension("wrong-document") }
            guard state["safe"] as? Bool == true else { return refuseSuspension(state["reason"] as? String ?? "edited-or-playing") }
            if index == 0 {
                guard let x = state["x"] as? Double, let y = state["y"] as? Double,
                      x.isFinite, y.isFinite else { return refuseSuspension("scroll-state") }
                scroll = (x, y)
            }
        }
        let size = ACRNavigationHistory(token, nil, 0)
        guard size > 0, size < 1_048_576 else { return refuseSuspension("history-size") }
        var bytes = [CChar](repeating: 0, count: Int(size) + 1)
        guard ACRNavigationHistory(token, &bytes, bytes.count) == size,
              let json = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: Int(size))) as? [String: Any],
              let entries = json["entries"] as? [String], let historyIndex = json["currentIndex"] as? Int else { return refuseSuspension("history-read") }
        let history = entries.compactMap(URL.init(string:))
        guard history.count == entries.count, history.indices.contains(historyIndex), history[historyIndex] == url else { return refuseSuspension("history-state") }
        guard canSuspendDocument, documentGeneration == generation, navigationState.committedURL == url else { return refuseSuspension("changed-document") }
        return BrowserSuspensionState(url: url, documentGeneration: generation, scrollX: scroll.0, scrollY: scroll.1,
                                      history: history, historyIndex: historyIndex)
    }

    private func refuseSuspension(_ reason: String) -> BrowserSuspensionState? {
        onEngineEvent?("suspension-refused", ["reason": reason])
        return nil
    }

    private var canSuspendDocument: Bool {
        !isDisposed && isReady && !navigationState.isLoading && !isProtectedFromSuspension && !isSuspended
    }

    private func suspensionWorld(frameID: String) async -> Int? {
        let params: [String: Any] = ["frameId": frameID, "worldName": "OrbitSuspension"]
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let (ok, result) = await devToolsCall("Page.createIsolatedWorld", params: text)
        guard ok, let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else { return nil }
        return json["executionContextId"] as? Int
    }

    private func evaluateSuspension(_ expression: String, context: Int) async -> [String: Any]? {
        let params: [String: Any] = ["expression": expression, "contextId": context, "returnByValue": true]
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let (ok, result) = await devToolsCall("Runtime.evaluate", params: text)
        guard ok, let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              json["exceptionDetails"] == nil, let remote = json["result"] as? [String: Any] else { return nil }
        return remote["value"] as? [String: Any]
    }

    static let suspensionEditObserver = #"""
    (() => {
      if (!globalThis.orbitSuspension) {
        globalThis.orbitSuspension = {edited:false};
        addEventListener('input', e => { if (e.isTrusted) orbitSuspension.edited=true; }, true);
        addEventListener('change', e => { if (e.isTrusted) orbitSuspension.edited=true; }, true);
      }
    })()
    """#

    private static let suspensionCheck = #"""
    (() => {
      if (!globalThis.orbitSuspension) return {safe:false,reason:'uninitialized-observer',documentURL:location.href};
      const roots = [document];
      let unsafe = orbitSuspension.edited;
      let changedField = false;
      let playing = false;
      for (let i=0; i<roots.length; ++i) {
        for (const element of roots[i].querySelectorAll('*')) {
          if (element.shadowRoot) roots.push(element.shadowRoot);
          if (element instanceof HTMLInputElement) {
            const valueInput = !['hidden','checkbox','radio','button','submit','reset','range','color'].includes(element.type);
            changedField ||= (valueInput && element.value !== element.defaultValue) || !!element.files?.length;
          } else if (element instanceof HTMLTextAreaElement) {
            changedField ||= element.value !== element.defaultValue;
          }
          playing ||= element instanceof HTMLMediaElement && !element.paused && !element.ended;
        }
      }
      unsafe ||= changedField || playing;
      return {safe:!unsafe, x:scrollX, y:scrollY,documentURL:location.href,
        reason:orbitSuspension.edited?'trusted-edit':changedField?'changed-field':playing?'playing-media':'safe'};
    })()
    """#

    /// Chromium owns page state and history restoration, including cache-only POST recovery.
    public func restoreAfterSuspension(_ state: BrowserSuspensionState) async {}

    public func suspendInPlace() -> BrowserSurfaceSuspensionResult {
        guard canSuspendDocument else { return .refused }
        isSuspended = true
        guard ACRDiscardTab(token) == 1 else { isSuspended = false; return .refused }
        onEngineEvent?("suspension-discarded", [:])
        return .suspended
    }

    func resumeDiscardedTab() {
        guard isSuspended, !isDisposed else { return }
        isSuspended = false
        _ = ACRRestoreDiscardedTab(token)
        onEngineEvent?("suspension-restored", [:])
    }
}
