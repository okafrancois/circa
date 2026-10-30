import AppKit
import Testing
import BrowserEngineConformance
@testable import Orbit

struct SettingsPresentationTests {
    @Test("Six public categories retain hidden subpane routes and numbered shortcuts")
    func categories() {
        #expect(BrowserSettingsSection.allCases == [.general, .profiles, .shortcuts, .links, .advanced, .about])
        #expect(!BrowserSettingsSection.allCases.contains(.spaces))
        #expect(!BrowserSettingsSection.allCases.contains(.privacy))
        #expect(BrowserSettingsSection(rawValue: "icon") == nil)
        #expect(BrowserSettingsSection.about.symbol == "app.dashed")
    }

    @MainActor
    @Test("Auxiliary pane navigation retains the selected profile and respects termination admission")
    func auxiliaryNavigation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [],
            defaultBrowser: .init(status: { .init(http: "synthetic", https: "synthetic", html: "synthetic") },
                canRequest: { false }, request: { Issue.record("Unexpected system request") }))
        try await model.createProfile(name: "Navigation Fixture")
        let profile = try #require(model.selectedProfileID)
        try await model.createSpace(name: "Navigation Space", profile: profile)
        let controller = BrowserSettingsWindowController(model: model)
        defer { controller.window?.close() }
        model.navigate(to: .spaces)
        #expect(model.settingsSection == .spaces && model.selectedProfileID == profile)
        #expect(controller.selectedToolbarIdentifier == nil)
        model.navigate(to: .privacy)
        #expect(model.settingsSection == .privacy && model.selectedProfileID == profile)
        try await model.suspendForTermination(timeout: .seconds(2))
        model.navigate(to: .profiles)
        #expect(model.settingsSection == .privacy)
        model.resumeAfterCancelledTermination()
        model.navigate(to: .about)
        #expect(controller.selectedToolbarIdentifier == BrowserSettingsSection.about.toolbarIdentifier)
        #expect(controller.window?.titleVisibility == .hidden)
        #expect(controller.window?.title == BrowserSettingsSection.about.title)
    }

    @Test("Window and pane transitions use the approved timing and displacement")
    func motion() {
        #expect(BrowserSettingsMotion.resizeDuration == 0.38)
        #expect(BrowserSettingsMotion.exitDuration == 0.09)
        #expect(BrowserSettingsMotion.enterDuration == 0.32)
        #expect(BrowserSettingsMotion.enterDelay == 0.10)
        #expect(BrowserSettingsMotion.rise == 6)
        #expect(BrowserSettingsMotion.pillDuration == 0.42)
        #expect(BrowserSettingsMotion.controlPoints == [0.19, 1, 0.22, 1])
        var first: [Float] = [0, 0], second: [Float] = [0, 0]
        BrowserSettingsMotion.timingFunction.getControlPoint(at: 1, values: &first)
        BrowserSettingsMotion.timingFunction.getControlPoint(at: 2, values: &second)
        #expect(first == [0.19, 1] && second == [0.22, 1])
    }
}
