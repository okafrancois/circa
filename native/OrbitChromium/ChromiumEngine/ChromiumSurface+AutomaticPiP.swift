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
        if enter { automaticPiPSourceWindow = hostView.window }
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
        guard enter else { return }
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
            guard enter, automaticPiPShouldEnter else { return }
            let expression = Self.enterAutomaticPiP
            guard let evaluation = try? JSONSerialization.data(withJSONObject: [
                "expression": expression, "contextId": context, "returnByValue": true,
                "userGesture": true, "awaitPromise": true
            ]) else { continue }
            automaticPiPPresentation?.finish()
            automaticPiPPresentation = ChromiumPictureInPicturePresentation(sourceWindow: automaticPiPSourceWindow)
            let (evaluated, resultData) = await devToolsCall("Runtime.evaluate", params: String(decoding: evaluation, as: UTF8.self))
            guard evaluated, let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  result["exceptionDetails"] == nil else { automaticPiPPresentation?.finish(); continue }
            if (result["result"] as? [String: Any])?["value"] as? Bool == true { return }
            automaticPiPPresentation?.finish()
        }
    }

    private static let enterAutomaticPiP = #"""
    (async () => {
      if (!document.pictureInPictureEnabled || document.pictureInPictureElement) return false;
      const videos = [...document.querySelectorAll('video')].filter(v =>
        !v.paused && !v.ended && v.readyState >= 2 && v.videoWidth > 0 && !v.disablePictureInPicture &&
        v.checkVisibility({checkOpacity:true, checkVisibilityCSS:true}) && (() => {
          const r = v.getBoundingClientRect();
          return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 &&
                 r.top < innerHeight && r.left < innerWidth;
        })());
      videos.sort((a,b) => b.videoWidth*b.videoHeight - a.videoWidth*a.videoHeight);
      const video = videos[0];
      if (!video) return false;
      try {
        await video.requestPictureInPicture();
        return document.pictureInPictureElement === video;
      } catch (_) { return false; }
    })()
    """#

}
