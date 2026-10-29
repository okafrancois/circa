import AppKit
import BrowserEngine
import Foundation

extension ChromiumSurface {
    /// The engine reports the page's declared theme colour natively; it wins when opaque. Without
    /// it (or on an engine without native colour state) read the meta hint with a bounded probe,
    /// then fall back to Chromium's rendered surface, including images and gradients.
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

    /// The declared theme colour as a tint, when the engine reports an opaque one.
    var nativeThemeTint: BrowserPageTint? {
        guard let argb = pageThemeColor, argb >> 24 == 0xFF else { return nil }
        return BrowserPageTint(red: UInt8((argb >> 16) & 0xFF), green: UInt8((argb >> 8) & 0xFF), blue: UInt8(argb & 0xFF))
    }

    private func measurePageTint() async {
        if let tint = nativeThemeTint {
            updatePageTint(tint)
            return
        }
        guard isBrowserCreated, !pageTintFailed, !navigationState.isLoading,
              let url = navigationState.committedURL,
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
              let window = hostView.window, window.occlusionState.contains(.visible),
              !hostView.isHiddenOrHasHiddenAncestor else { return }
        let generation = documentGeneration
        let size = hostView.bounds.size
        guard (try? await beginSnapshotCapture()) != nil else { return }
        defer { snapshotCaptureInFlight = false }
        guard !Task.isCancelled, generation == documentGeneration, pageTintObservationEnabled else { return }
        if let api = pagePerformance {
            guard size.width.isFinite, size.width >= 1, size.width <= CGFloat(Int32.max), size.height >= 2 else { return }
            var request = BrowserNativeCaptureRequest(outputWidth: 64, outputHeight: 1)
            request.width = Int32(size.width.rounded(.down)); request.height = 2
            guard let captured = try? await captureNativeSnapshot(api, request: request) else { return }
            guard !Task.isCancelled, !isDisposed, generation == documentGeneration,
                  size == hostView.bounds.size, !pageTintFailed, pageTintObservationEnabled,
                  window === hostView.window, window.occlusionState.contains(.visible),
                  !hostView.isHiddenOrHasHiddenAncestor else { return }
            if let image = ChromiumSnapshotDecoder.nativeImage(captured),
               let tint = BrowserPageTint.sampledTopEdge(image) {
                updatePageTint(nativeThemeTint ?? tint)
                return
            }
            guard captured.status == .unavailable || captured.status == .timedOut else { return }
        } else {
            // Engines without native theme/capture state retain the bounded meta-colour probe.
            let params = ["expression": Self.pageTintProbe, "returnByValue": true] as [String: Any]
            guard let json = try? JSONSerialization.data(withJSONObject: params) else { return }
            let (ok, data) = await devToolsCall("Runtime.evaluate", params: String(decoding: json, as: UTF8.self))
            guard ok, !Task.isCancelled, generation == documentGeneration, !pageTintFailed, pageTintObservationEnabled,
                  window === hostView.window, window.occlusionState.contains(.visible),
                  !hostView.isHiddenOrHasHiddenAncestor,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = root["result"] as? [String: Any], let value = result["value"] as? [String: Any] else { return }
            if let bytes = value["color"] as? [Int], bytes.count == 3, bytes.allSatisfy({ (0...255).contains($0) }) {
                updatePageTint(nativeThemeTint ?? BrowserPageTint(red: UInt8(bytes[0]), green: UInt8(bytes[1]), blue: UInt8(bytes[2])))
                return
            }
        }
        // A CDP clip (even with captureBeyondViewport:false) temporarily resizes the widget.
        // Capture the unmodified viewport instead; only its first row is read below.
        let capture: [String: Any] = ["format": "png", "captureBeyondViewport": false]
        guard let json = try? JSONSerialization.data(withJSONObject: capture) else { return }
        let (captured, png) = await devToolsCall("Page.captureScreenshot", params: String(decoding: json, as: UTF8.self))
        guard captured, !Task.isCancelled, generation == documentGeneration, !pageTintFailed else { return }
        let worker = Task.detached(priority: .utility) {
            guard let decoded = ChromiumSnapshotDecoder.decode(png, width: nil, generation: generation) else { return nil as BrowserPageTint? }
            return BrowserPageTint.sampledTopEdge(decoded.snapshot.image)
        }
        let tint = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, !isDisposed, generation == documentGeneration, !pageTintFailed,
              pageTintObservationEnabled, window === hostView.window,
              window.occlusionState.contains(.visible), !hostView.isHiddenOrHasHiddenAncestor, let tint else { return }
        updatePageTint(nativeThemeTint ?? tint)
    }
}
