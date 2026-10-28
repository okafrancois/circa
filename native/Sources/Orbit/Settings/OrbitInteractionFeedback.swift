import AppKit
import BrowserCore

/// Only intentional interface effects; AppKit's validation beeps and website audio are separate.
@MainActor
final class OrbitInteractionFeedback {
    var preferences = BrowserInteractionPreferences()
    var playCaptureSound: () -> Void = { NSSound(named: .init("Pop"))?.play() }
    var performAlignment: () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func didCapture() {
        if preferences.playSoundEffects { playCaptureSound() }
    }

    func reorderSnapped() {
        if preferences.hapticFeedback { performAlignment() }
    }
}
