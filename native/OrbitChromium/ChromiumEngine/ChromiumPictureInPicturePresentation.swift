import AppKit

/// Adapts only the outer AppKit window created by a native video PiP request. Chromium owns
/// the video surface, hit testing, playback controls, accessibility and close/return actions.
@MainActor
final class ChromiumPictureInPicturePresentation {
    private let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
    private weak var sourceWindow: NSWindow?
    private var observations: [NSObjectProtocol] = []
    private weak var window: NSWindow?
    private var opacityObservation: NSKeyValueObservation?
    private var isArranging = false

    init?(sourceWindow: NSWindow?) {
        let source = sourceWindow ?? NSApp.windows.first {
            $0.isVisible && $0.level == .normal && $0.styleMask.contains(.titled)
        }
        guard let source else { return nil }
        self.sourceWindow = source
        for name in [NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let candidate = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    self?.consider(candidate)
                }
            })
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.finish()
        }
    }

    func finish() {
        for observer in observations { NotificationCenter.default.removeObserver(observer) }
        observations.removeAll()
        opacityObservation = nil
    }

    func prepareForReturn() {
        finish()
    }

    func close() {
        prepareForReturn()
        if let window {
            window.parent?.removeChildWindow(window)
            window.performClose(nil)
        }
        window = nil
    }

    private func consider(_ candidate: NSWindow) {
        guard !isArranging, window == nil, !existingWindows.contains(ObjectIdentifier(candidate)),
              candidate.styleMask.contains(.fullSizeContentView), !candidate.styleMask.contains(.titled),
              candidate.level == .floating,
              candidate.collectionBehavior.contains(.canJoinAllSpaces), candidate.isVisible else { return }
        window = candidate
        finish()
        isArranging = true
        defer { isArranging = false }
        let aspect = candidate.frame.width / max(1, candidate.frame.height)
        let size = NSSize(width: 224, height: 224 / aspect)
        guard let sourceWindow else { return }
        let target = NSRect(x: sourceWindow.frame.maxX - size.width,
                            y: sourceWindow.frame.maxY - size.height,
                            width: size.width, height: size.height)
        candidate.minSize = size
        candidate.contentMinSize = size
        candidate.isOpaque = false
        candidate.backgroundColor = .clear
        candidate.hasShadow = true
        candidate.contentView?.wantsLayer = true
        candidate.contentView?.layer?.cornerRadius = 6
        candidate.contentView?.layer?.masksToBounds = true
        candidate.contentView?.layer?.borderWidth = 0.5
        candidate.contentView?.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        candidate.animationBehavior = .none
        // Automatic entry appears at its final frame without native opacity interpolation.
        opacityObservation = candidate.observe(\.alphaValue, options: [.new]) { window, change in
            let opacity = change.newValue ?? 1
            MainActor.assumeIsolated {
                if opacity < 1 { window.alphaValue = 1 }
            }
        }
        candidate.alphaValue = 1
        candidate.hidesOnDeactivate = false
        candidate.setFrame(target, display: false)
        candidate.invalidateShadow()
    }
}
