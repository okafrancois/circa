import AppKit
import QuartzCore

/// Adapts only the outer AppKit window created by a native video PiP request. Chromium owns
/// the video surface, hit testing, playback controls, accessibility and close/return actions.
@MainActor
final class ChromiumPictureInPicturePresentation {
    private let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
    private let screen: NSScreen
    private weak var animationParent: NSWindow?
    private var observations: [NSObjectProtocol] = []
    private weak var window: NSWindow?
    private var animation: Task<Void, Never>?
    private var opacityObservation: NSKeyValueObservation?
    private var isArranging = false

    init?(sourceWindow: NSWindow?) {
        let source = sourceWindow ?? NSApp.windows.first {
            $0.isVisible && $0.level == .normal && $0.styleMask.contains(.titled)
        }
        guard let source, let screen = source.screen else { return nil }
        self.screen = screen
        animationParent = source
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
        animation?.cancel()
        animation = nil
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
        let target = NSRect(x: screen.visibleFrame.maxX - size.width - 10,
                            y: screen.visibleFrame.maxY - size.height - 10,
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
        // The outer presentation supplies the opening motion; suppress the widget fade while
        // it runs, then release the observation so subsequent native interactions stay native.
        opacityObservation = candidate.observe(\.alphaValue, options: [.new]) { window, change in
            let opacity = change.newValue ?? 1
            MainActor.assumeIsolated {
                if opacity < 1 { window.alphaValue = 1 }
            }
        }
        candidate.alphaValue = 1
        // Child windows may travel above the menu bar without AppKit constraining their frame.
        // Release this temporary ordering relationship as soon as entry settles.
        let parent = animationParent
        let nativeLevel = candidate.level
        let nativeBehavior = candidate.collectionBehavior
        parent?.addChildWindow(candidate, ordered: .above)
        candidate.setFrame(target.offsetBy(dx: 0, dy: size.height + 10), display: false)
        let start = CACurrentMediaTime()
        animation = Task { [weak candidate, weak parent] in
            guard let candidate else { return }
            defer {
                parent?.removeChildWindow(candidate)
                if candidate.isVisible {
                    candidate.level = nativeLevel
                    candidate.collectionBehavior = nativeBehavior
                }
            }
            while candidate.isVisible, !Task.isCancelled {
                let elapsed = CACurrentMediaTime() - start
                let progress = min(1, elapsed / 0.45)
                let remaining = (exp(-6.1 * progress) - exp(-6.1)) / (1 - exp(-6.1))
                candidate.setFrame(target.offsetBy(dx: 0, dy: (size.height + 10) * remaining), display: false)
                if progress == 1 { candidate.invalidateShadow(); return }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }
}
