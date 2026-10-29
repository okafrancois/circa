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
        guard !isDisposed, isBrowserCreated, (enter != automaticPiPShouldEnter || isSelected != automaticPiPIsSelected) else { return }
        if enter { automaticPiPSourceWindow = hostView.window }
        automaticPiPShouldEnter = enter
        automaticPiPIsSelected = isSelected
        automaticPiPRevision &+= 1
        guard automaticPiPTask == nil else { return }
        automaticPiPTask = Task { [weak self] in
            guard let self else { return }
            defer { automaticPiPTask = nil }
            repeat {
                let revision = automaticPiPRevision
                let enter = automaticPiPShouldEnter
                let generation = documentGeneration
                let returning = automaticPiPIsSelected
                await reconcileAutomaticPiP(enter: enter, returning: returning, generation: generation)
                guard !isDisposed, !Task.isCancelled else { return }
                if revision == automaticPiPRevision { return }
            } while true
        }
    }

    /// Each frame gets an isolated world. Cross-origin players use their own native DOM and
    /// permissions policy; no Node/IPC is exposed and page replacements of DOM APIs do not run.
    private func reconcileAutomaticPiP(enter: Bool, returning: Bool, generation: UInt64) async {
        if returning {
            guard let session = automaticPiPSession else { return }
            automaticPiPSession = nil
            guard session.generation == generation else { return }
            automaticPiPPresentation?.prepareForReturn()
            // Exit through the renderer so Chromium returns the existing player inline without
            // pausing it. No added fade, scale or travel accompanies the window removal.
            _ = await evaluatePiP(BrowserAutomaticPiPScript.returnToSource, context: session.context)
            return
        }
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
            let expression = BrowserAutomaticPiPScript.enter
            guard let evaluation = try? JSONSerialization.data(withJSONObject: [
                "expression": expression, "contextId": context, "returnByValue": true,
                "userGesture": true, "awaitPromise": true
            ]) else { continue }
            automaticPiPPresentation?.finish()
            automaticPiPPresentation = ChromiumPictureInPicturePresentation(sourceWindow: automaticPiPSourceWindow)
            let (evaluated, resultData) = await evaluateAutomaticPiP(evaluation)
            guard evaluated, let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  result["exceptionDetails"] == nil else { automaticPiPPresentation?.finish(); continue }
            if (result["result"] as? [String: Any])?["value"] as? Bool == true {
                automaticPiPSession = (context, generation)
                return
            }
            automaticPiPPresentation?.finish()
        }
    }

    private func evaluateAutomaticPiP(_ parameters: Data) async -> (Bool, Data) {
        let scoped = ACRSetAutomaticPiP(token, 1) == 1
        guard scoped || ACRPatchLevel() < 9 else { return (false, Data()) }
        defer { if scoped { _ = ACRSetAutomaticPiP(token, 0) } }
        return await devToolsCall("Runtime.evaluate", params: String(decoding: parameters, as: UTF8.self))
    }

    private func evaluatePiP(_ expression: String, context: Int) async -> (Bool, Data) {
        guard let parameters = try? JSONSerialization.data(withJSONObject: [
            "expression": expression, "contextId": context, "returnByValue": true, "awaitPromise": true
        ]) else { return (false, Data()) }
        return await devToolsCall("Runtime.evaluate", params: String(decoding: parameters, as: UTF8.self))
    }
}
