import AppKit
import BrowserCore
import BrowserShell
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
        #expect(BrowserSettingsSection.about.symbol == "info.circle")
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

extension SettingsPresentationTests {
    @Test("Version text includes the localized prefix and preserves synthetic build metadata")
    func versionFormat() {
        #expect(BrowserSettingsAbout.versionDescription(info: ["CFBundleShortVersionString": "1.4.2", "CFBundleVersion": "142"]) == "Version 1.4.2 (142)")
        #expect(BrowserSettingsAbout.versionDescription(info: ["CFBundleShortVersionString": "1.4.2", "CFBundleVersion": "fixture.20261030"]) == "Version 1.4.2 (fixture.20261030)")
        #expect(BrowserSettingsAbout.versionDescription(info: [:]) == "Version Development build (Development build)")
    }

    @MainActor
    @Test("New Space rows create distinct identities and keep edits scoped to the selected Space")
    func spaceRowBindings() async throws {
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [])
        try await model.createProfile(name: "List Fixture")
        let profile = try #require(model.selectedProfileID)
        let first = try await model.createSpace(name: "New Space", profile: profile)
        let second = try await model.createSpace(name: "New Space", profile: profile)
        #expect(first != second)
        try await model.renameSpace(second, name: "Renamed")
        await model.reload()
        #expect(model.catalog.spaces.first { $0.id == first }?.name == "New Space")
        #expect(model.catalog.spaces.first { $0.id == second }?.name == "Renamed")
        model.queueSpaceIconEdit(spaceID: second, profileID: profile, icon: .grapheme("🌿"))
        try await model.waitForPendingActions()
        #expect(environment.settings.document.space(second).iconSelection == .grapheme("🌿"))
        #expect(environment.settings.document.space(first).iconSelection == .none)
        var selected = first
        let space = try #require(model.catalog.spaces.first { $0.id == second })
        let row = BrowserSettingsSpaceRow(space: space, theme: space.theme, icon: .grapheme("🌿"), isSelected: false) { selected = second }
        row.select()
        #expect(selected == second)
        #expect(row.space.name == "Renamed" && row.icon == .grapheme("🌿"))
    }

    @MainActor
    @Test("Compact name fields save on focus departure and never submit marked text")
    func compactNameCommit() {
        let draft = BrowserSettingsNameDraft(name: "Original")
        let field = BrowserSettingsNameTextField()
        var saved: [String] = []
        field.draft = draft
        field.savesOnEndEditing = true
        field.onSubmit = { draft.submit { saved.append($0) } }
        draft.text = "Edited"
        draft.beginComposition()
        draft.submit { saved.append($0) }
        #expect(saved.isEmpty)
        field.stringValue = "Committed"
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(saved == ["Committed"])
        draft.receivePersisted("Committed")
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(saved == ["Committed"])
    }

    @MainActor
    @Test("Destructive settings actions use system red independently of the control accent")
    func destructiveInk() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let ink = try #require(OrbitSettingsStyle.destructiveColor.resolved(for: appearance).usingColorSpace(.sRGB))
            #expect(ink.redComponent > 0.8 && ink.greenComponent < 0.5 && ink.blueComponent < 0.5)
        }
    }
}


extension SettingsPresentationTests {
    @MainActor
    @Test("Settings gradient selection preserves the Space's Frost, grain and appearance mode")
    func gradientPreservesControls() async throws {
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [])
        try await model.createProfile(name: "Theme Fixture")
        let profile = try #require(model.selectedProfileID)
        let id = try await model.createSpace(name: "Frost Fixture", profile: profile)
        var original = BrandPalette.spaceGradients[0].theme(mode: .dark)
        original.frost = true
        original.noise = 0.27
        try await environment.store.setSpaceTheme(original, for: id, profileID: profile)
        await model.reload()
        let space = try #require(model.catalog.spaces.first { $0.id == id })
        let picker = BrowserSettingsGradientPicker(model: model, space: space)
        for preset in BrandPalette.spaceGradients {
            picker.select(preset)
            try await model.waitForPendingActions()
            let saved = try #require(model.catalog.spaces.first { $0.id == id }?.theme)
            #expect(saved.light == preset.theme().light)
            #expect(saved.dark == preset.theme().dark)
            #expect(saved.mode == .dark)
            #expect(saved.frost)
            #expect(saved.noise == 0.27)
        }
    }
}
