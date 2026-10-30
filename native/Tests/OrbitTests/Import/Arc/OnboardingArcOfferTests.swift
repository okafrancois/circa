import BrowserCore
import Foundation
import Testing
import OrbitImportSynthetic
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

extension OnboardingArcOfferTests {
    @Test("An Arc import skips both inherited steps; Back jumps over their dimmed dots")
    @MainActor
    func inheritedSteps() {
        let source = OrbitOnboardingSource(id: OrbitApplication.onboardingArcSourceID, name: "Arc", bundleIdentifier: nil, profiles: [])
        var flow = OrbitOnboardingFlow(step: .importSource, sources: [source], syncAvailability: .available)
        flow.select(source: source)
        #expect(flow.skippedSteps == [.favourites, .theme])
        #expect(flow.advance() && flow.step == .sync)
        flow.selectSync(false)
        #expect(flow.advance() && flow.step == .defaultBrowser)
        #expect(flow.goBack() && flow.step == .sync)
        #expect(flow.goBack() && flow.step == .importSource)
        flow.importChoice = BrowserOnboardingRecord.ImportChoice.none
        #expect(flow.skippedSteps.isEmpty)
        #expect(flow.advance() && flow.step == .favourites)
    }
}

@MainActor
struct ArcSunsetOnboardingTests {
    struct MissingKey: ArcSiteSessionKeyProviding {
        func sourcePassword() throws -> Data { throw ArcAuthenticationError.sourceKeyUnavailable }
        func targetPassword() throws -> Data { Issue.record("No target key should be read"); return Data() }
    }
    @Test("Onboarding retains structural success and explains unavailable connections")
    func missingKeyContinues() async throws {
        let root = try ArcSyntheticData.temporaryDirectory("sunset-onboarding")
        defer { try? FileManager.default.removeItem(at: root) }
        var explained = false
        try await OrbitOnboardingImportPreparation.importConnections(.init(sourceRoot: root.appendingPathComponent("source"), profiles: []),
            dataRoot: root.appendingPathComponent("target"), keys: MissingKey()) { explained = true }
        #expect(explained)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("target/SessionImport/Backups").path))
    }
    @Test("The timeless import hint describes structural data and passwords")
    func hint() {
        #expect(ArcImportText.localFilesHint.contains("even after Arc stops working"))
        #expect(!ArcImportText.localFilesHint(passwordsAvailable: false).contains("passwords"))
        #expect(ArcImportText.localFilesHint(passwordsAvailable: true) == "Coming from Arc? Your Spaces, tabs and passwords come with you, even after Arc stops working.")
        #expect(ArcImportText.confirmation(.init()).contains(ArcImportText.localFilesHint))
    }
}


extension ArcSunsetOnboardingTests {
    @Test("Import hints depend on source data rather than an installed application")
    func dataOnlyHint() {
        let source = URL(fileURLWithPath: "/tmp/synthetic-import-source")
        #expect(ArcImportText.localFilesHint(source: source, fileExists: { _ in false }) == nil)
        #expect(ArcImportText.localFilesHint(source: source, fileExists: {
            $0 == source.appendingPathComponent("StorableSidebar.json").path
        }) == ArcImportText.localFilesHint)
        let dataOnly = OrbitOnboardingSource(id: OrbitApplication.onboardingArcSourceID, name: "Arc", bundleIdentifier: nil, profiles: [])
        #expect(OrbitOnboardingText.importNote(sources: [dataOnly]) == ArcImportText.localFilesHint)
        #expect(OrbitOnboardingText.importNote(sources: []) == OrbitOnboardingText.importNote)
    }
}
