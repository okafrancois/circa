import Foundation
import BrowserEngine
import OrbitChromiumBridge

extension ChromiumSurface {
    public func showDeveloperPanel(_ panel: BrowserDeveloperPanel) throws {
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        if panel == .elements { try perform(.inspectElements); return }
        guard ACRShowDevToolsPanel(token, panel.rawValue) == 1 else { throw BrowserEngineError.unsupportedOperation }
    }
    public func updateAutomaticPictureInPicture(isSelected: Bool, allowed: Bool) {
        let enter = !isSelected && allowed
        guard !isDisposed, isBrowserCreated, enter != automaticPiPShouldEnter else { return }
        automaticPiPShouldEnter = enter
        automaticPiPRevision &+= 1
        guard automaticPiPTask == nil else { return }
        automaticPiPTask = Task { [weak self] in
            guard let self else { return }
            defer { automaticPiPTask = nil }
            repeat {
                let revision = automaticPiPRevision
                let enter = automaticPiPShouldEnter
                let generation = documentGeneration
                await reconcileAutomaticPiP(enter: enter, generation: generation)
                guard !isDisposed, !Task.isCancelled else { return }
                if revision == automaticPiPRevision { return }
            } while true
        }
    }

    /// Each frame gets an isolated world. Cross-origin players use their own native DOM and
    /// permissions policy; no Node/IPC is exposed and page replacements of DOM APIs do not run.
    private func reconcileAutomaticPiP(enter: Bool, generation: UInt64) async {
        let (ok, treeData) = await devToolsCall("Page.getFrameTree")
        guard ok, let json = try? JSONSerialization.jsonObject(with: treeData) as? [String: Any],
              let tree = json["frameTree"] as? [String: Any] else { return }
        func frames(_ node: [String: Any]) -> [String] {
            let id = (node["frame"] as? [String: Any])?["id"] as? String
            return (id.map { [$0] } ?? []) + (node["childFrames"] as? [[String: Any]] ?? []).flatMap(frames)
        }
        for frame in frames(tree) {
            guard !isDisposed, documentGeneration == generation, !Task.isCancelled else { return }
            guard let parameters = try? JSONSerialization.data(withJSONObject: ["frameId": frame, "worldName": "OrbitAutomaticPiP"]) else { continue }
            let (created, worldData) = await devToolsCall("Page.createIsolatedWorld", params: String(decoding: parameters, as: UTF8.self))
            guard created, let world = try? JSONSerialization.jsonObject(with: worldData) as? [String: Any],
                  let context = world["executionContextId"] as? Int,
                  documentGeneration == generation, !isDisposed else { continue }
            let expression = enter ? Self.enterAutomaticPiP : Self.exitAutomaticPiP
            guard let evaluation = try? JSONSerialization.data(withJSONObject: [
                "expression": expression, "contextId": context, "returnByValue": true,
                "userGesture": true, "awaitPromise": true
            ]) else { continue }
            let (evaluated, resultData) = await devToolsCall("Runtime.evaluate", params: String(decoding: evaluation, as: UTF8.self))
            guard evaluated, let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  result["exceptionDetails"] == nil else { continue }
            if enter, (result["result"] as? [String: Any])?["value"] as? Bool == true { return }
        }
    }

    private static let enterAutomaticPiP = #"""
    (async () => {
      if (!document.pictureInPictureEnabled || document.pictureInPictureElement) return false;
      const videos = [...document.querySelectorAll('video')].filter(v =>
        !v.paused && !v.ended && v.readyState >= 2 && v.videoWidth > 0 && !v.disablePictureInPicture);
      videos.sort((a,b) => b.videoWidth*b.videoHeight - a.videoWidth*a.videoHeight);
      const video = videos[0];
      if (!video) return false;
      try {
        await video.requestPictureInPicture();
        globalThis.orbitAutomaticPiPVideo = video;
        return document.pictureInPictureElement === video;
      } catch (_) { return false; }
    })()
    """#

    private static let exitAutomaticPiP = #"""
    (async () => {
      const video = globalThis.orbitAutomaticPiPVideo;
      globalThis.orbitAutomaticPiPVideo = null;
      if (video && document.pictureInPictureElement === video) {
        try { await document.exitPictureInPicture(); } catch (_) {}
      }
      return true;
    })()
    """#
}
