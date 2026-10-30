import AppKit
import CoreGraphics

struct OrbitIdleUpdateSignals: Equatable {
    var idleSeconds: TimeInterval = 0
    var screensaver = false
    var locked = false
    var mediaPlaying = true

    var permitsInstallation: Bool {
        idleSeconds.isFinite && idleSeconds >= 5 && !mediaPlaying
            && (idleSeconds >= 300 || screensaver || locked)
    }
}

/// Signals contain no page, window title, or user input content.
@MainActor
final class OrbitIdleUpdateSignalsSource {
    private var screensaver = false
    private var locked = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = DistributedNotificationCenter.default()
        for (name, value, isLock) in [
            ("com.apple.screensaver.didstart", true, false),
            ("com.apple.screensaver.didstop", false, false),
            ("com.apple.screenIsLocked", true, true),
            ("com.apple.screenIsUnlocked", false, true)
        ] {
            observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if isLock { self?.locked = value } else { self?.screensaver = value }
                }
            })
        }
    }

    func sample(mediaPlaying: Bool) -> OrbitIdleUpdateSignals {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let sessionLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? locked
        return .init(idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState,
            eventType: CGEventType(rawValue: UInt32.max)!), screensaver: screensaver,
            locked: sessionLocked, mediaPlaying: mediaPlaying)
    }

    isolated deinit {
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
