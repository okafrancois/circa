import AppKit
import BrowserCore

/// Synthetic review fixtures use the production import text and onboarding components.
@MainActor
enum BrowserImportBrandingCapture {
    static func alert() -> OrbitFrostAlert {
        let alert = OrbitFrostAlert()
        alert.messageText = ArcImportText.confirmTitle
        alert.informativeText = ArcImportText.confirmation(.init())
        alert.addButton(withTitle: ArcImportText.importButton)
        alert.addButton(withTitle: ArcImportText.cancel)
        return alert
    }

    static func onboarding() -> OrbitOnboardingWindowController {
        let source = OrbitOnboardingSource(id: OrbitApplication.onboardingArcSourceID, name: ArcBrowserImportAdapter().descriptor.name,
                                           bundleIdentifier: nil, profiles: [])
        var services = OrbitOnboardingServices()
        services.sourceArtwork = { OrbitOnboardingArtwork.artwork(for: $0, synthetic: true) }
        return OrbitOnboardingWindowController(flow: .init(step: .importSource, sources: [source], syncAvailability: .unavailable), services: services, themeTarget: nil)
    }
}
