import BrowserCore
import Foundation
import Testing
@testable import Orbit

/// The first-run onboarding replaces the Arc import offer, and its import step runs Arc in place.
struct OnboardingArcOfferTests {
    @Test("The Arc import offer never shows once an onboarding record exists")
    func arcOfferReplaced() {
        let location = ArcImportDataLocation(sessionFile: URL(fileURLWithPath: "/tmp/orbit-onboarding-offer/session.json"))
        let source = URL(fileURLWithPath: "/tmp/orbit-onboarding-offer/Arc")
        let onboarding = BrowserOnboardingFiles.recordFile(dataDirectory: location.dataDirectory).path
        func eligible(_ existing: Set<String>) -> Bool {
            ArcImportFirstRunOffer.isEligible(bundleIdentifier: ProductIdentity.bundleIdentifier, arguments: ["Orbit"], restoredWindowCount: 0,
                                              location: location, orbitSource: source, fileExists: { existing.contains($0) })
        }
        let arc = source.appendingPathComponent("StorableSidebar.json").path
        #expect(eligible([arc]))
        #expect(!eligible([arc, onboarding]))
    }

    @Test("The onboarding records Arc by its import descriptor id")
    @MainActor
    func arcChoice() {
        let source = OrbitOnboardingSource(id: OrbitApplication.onboardingArcSourceID, name: "Arc", bundleIdentifier: nil, profiles: [])
        #expect(OrbitApplication.onboardingArcSourceID == ArcBrowserImportAdapter().descriptor.id)
        var flow = OrbitOnboardingFlow(step: .importSource, sources: [source], syncAvailability: .unavailable)
        flow.select(source: source)
        #expect(flow.importChoice == .browser(sourceID: ArcBrowserImportAdapter().descriptor.id, profileDirectory: nil))
        #expect(flow.canAdvance)
    }
}
