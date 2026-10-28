import AppKit
import BrowserEngine
import Foundation
import ImageIO

extension ChromiumSurface {
    /// CEF 156's CefDisplayHandler/CefBrowserHost expose neither theme-color nor WebContents'
    /// background. CDP has no equivalent getter. Read only the meta hint with a bounded probe;
    /// all other colours come from Chromium's rendered surface, including images and gradients.
    static let pageTintProbe = #"""
    (() => {
      if (document.readyState === 'loading') return null;
      let color = null;
      for (const meta of document.querySelectorAll('meta[name="theme-color" i]')) {
        if (meta.media && !matchMedia(meta.media).matches) continue;
        const value = meta.content.trim();
        if (!value || !CSS.supports('color', value) || /currentcolor|var\(/i.test(value)) continue;
        const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1;
        const context = canvas.getContext('2d', {willReadFrequently:true});
        context.fillStyle = value; context.fillRect(0, 0, 1, 1);
        const bytes = context.getImageData(0, 0, 1, 1).data;
        if (bytes[3] === 255) { color = Array.from(bytes).slice(0, 3); break; }
      }
      return {color};
    })()
    """#

    public func setPageTintObservationEnabled(_ enabled: Bool) {
        guard enabled != pageTintObservationEnabled else { return }
        pageTintObservationEnabled = enabled
        restartPageTintObservation()
    }

    func restartPageTintObservation() {
        pageTintTask?.cancel()
        pageTintTask = nil
        guard pageTintObservationEnabled, !isDisposed else { return }
        // Weak between ticks: the task must not keep a retired surface alive.
        pageTintTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.measurePageTint()
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                guard self != nil else { return }
            }
        }
    }

    private func measurePageTint() async {
        guard isBrowserCreated, !pageTintFailed,
              let url = navigationState.committedURL,
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
              hostView.window != nil, !hostView.isHiddenOrHasHiddenAncestor else { return }
        let generation = documentGeneration
        let params = ["expression": Self.pageTintProbe, "returnByValue": true] as [String: Any]
        guard let json = try? JSONSerialization.data(withJSONObject: params) else { return }
        let (ok, data) = await devToolsCall("Runtime.evaluate", params: String(decoding: json, as: UTF8.self))
        guard ok, !Task.isCancelled, generation == documentGeneration, !pageTintFailed,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let value = result["value"] as? [String: Any] else { return }
        if let bytes = value["color"] as? [Int], bytes.count == 3, bytes.allSatisfy({ (0...255).contains($0) }) {
            updatePageTint(BrowserPageTint(red: UInt8(bytes[0]), green: UInt8(bytes[1]), blue: UInt8(bytes[2])))
            return
        }
        // A CDP clip (even with captureBeyondViewport:false) temporarily resizes the widget.
        // Capture the unmodified viewport instead; only its first row is read below.
        let capture: [String: Any] = ["format": "png", "captureBeyondViewport": false]
        guard let json = try? JSONSerialization.data(withJSONObject: capture) else { return }
        let (captured, png) = await devToolsCall("Page.captureScreenshot", params: String(decoding: json, as: UTF8.self))
        guard captured, !Task.isCancelled, generation == documentGeneration, !pageTintFailed,
              let object = try? JSONSerialization.jsonObject(with: png) as? [String: Any],
              let encoded = object["data"] as? String, let bytes = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let tint = BrowserPageTint.sampledTopEdge(image) else { return }
        updatePageTint(tint)
    }
}
