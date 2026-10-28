import AppKit
import BrowserEngine
import Foundation

extension ChromiumSurface: BrowserLinkGeometrySource {
    public var linkActivationPoint: NSPoint? {
        guard let activation = (hostView as? ChromiumHostView)?.linkActivation,
              activation.generation == documentGeneration,
              ProcessInfo.processInfo.systemUptime - activation.timestamp < 1,
              NSApp.currentEvent?.type != .keyDown else { return nil }
        return activation.point
    }

    public func linkGeometry(at point: NSPoint) async -> BrowserLinkGeometry? {
        guard !isDisposed, isBrowserCreated, point.x.isFinite, point.y.isFinite else { return nil }
        let generation = documentGeneration
        let zoom = pageZoom
        func call(_ method: String, _ parameters: [String: Any]) async -> [String: Any]? {
            guard let data = try? JSONSerialization.data(withJSONObject: parameters) else { return nil }
            let (ok, result) = await devToolsCall(method, params: String(decoding: data, as: UTF8.self), timeout: .milliseconds(250))
            return ok ? (try? JSONSerialization.jsonObject(with: result) as? [String: Any]) : nil
        }
        // Blink's hit test takes document CSS coordinates; box-model quads are viewport CSS
        // coordinates. Convert the pointer before hit testing, and the result after zoom.
        guard let metrics = await call("Page.getLayoutMetrics", [:]),
              let viewport = metrics["cssVisualViewport"] as? [String: Any],
              let scrollX = viewport["pageX"] as? Double, let scrollY = viewport["pageY"] as? Double,
              let hit = await call("DOM.getNodeForLocation", ["x": Int(point.x / zoom + scrollX),
                                                            "y": Int(point.y / zoom + scrollY),
                                                            "includeUserAgentShadowDOM": false]),
              let node = hit["backendNodeId"] as? Int, let frame = hit["frameId"] as? String,
              let world = await call("Page.createIsolatedWorld", ["frameId": frame, "worldName": "OrbitLinkGeometry"]),
              let context = world["executionContextId"] as? Int,
              let resolved = await call("DOM.resolveNode", ["backendNodeId": node, "executionContextId": context]),
              let object = resolved["object"] as? [String: Any], let identifier = object["objectId"] as? String else { return nil }
        let result = await call("Runtime.callFunctionOn", ["objectId": identifier,
            "functionDeclaration": "function() { return this.closest('a[href],area[href]'); }", "returnByValue": false])
        let link = (result?["result"] as? [String: Any])?["objectId"] as? String
        var rect: NSRect?
        var cornerRadius: CGFloat = 0
        if let link, let box = await call("DOM.getBoxModel", ["objectId": link]),
           let model = box["model"] as? [String: Any], let quad = model["border"] as? [Double], quad.count == 8,
           quad.allSatisfy(\.isFinite) {
            let xs = stride(from: 0, to: 8, by: 2).map { quad[$0] * zoom }
            let ys = stride(from: 1, to: 8, by: 2).map { quad[$0] * zoom }
            rect = NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            let style = await call("Runtime.callFunctionOn", ["objectId": link,
                "functionDeclaration": "function() { return parseFloat(getComputedStyle(this).borderTopLeftRadius) || 0; }",
                "returnByValue": true])
            if let radius = (style?["result"] as? [String: Any])?["value"] as? Double, radius.isFinite {
                cornerRadius = max(0, radius * zoom)
            }
        }
        _ = await call("Runtime.releaseObject", ["objectId": identifier])
        if let link { _ = await call("Runtime.releaseObject", ["objectId": link]) }
        guard !isDisposed, documentGeneration == generation, pageZoom == zoom, let rect, rect.width > 0, rect.height > 0 else { return nil }
        return BrowserLinkGeometry(bounds: rect, cornerRadius: cornerRadius)
    }
}
