import AppKit
import BrowserCore
import BrowserEngineConformance
import Testing
@testable import Orbit

@MainActor
private final class ThemeCommitGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var entered = false
    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        isOpen = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

extension NativeWebKitTests {
@Suite("Applied theme ordered writers R2", .serialized)
@MainActor
struct AppliedThemeOrderingR2Tests {
    @Test("Appearance finishes an explicit material draft and leaves another Space editor open")
    func explicitSurfaceAndUnrelatedEditor() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let other = try await environment.store.createSpace(name: "Synthetic other Space", profileID: profile)
        let first = try await environment.makeWindow(spaceID: space)
        let second = try await environment.makeWindow(spaceID: other)
        defer { first.window?.close(); second.window?.close() }
        first.openThemeEditor(for: space, animated: false)
        second.openThemeEditor(for: other, animated: false)
        let editor = try #require(first.themeEditor)
        let unrelated = try #require(second.themeEditor)
        editor.view.swatches[3].performClick(nil)
        editor.view.surfaceMaterial.selectItem(at: try #require(BrowserThemeSurface.Material.allCases.firstIndex(of: .frosted)))
        _ = editor.view.surfaceMaterial.sendAction(editor.view.surfaceMaterial.action!, to: editor.view.surfaceMaterial.target)
        editor.view.surfaceTransparency.doubleValue = 0.21
        _ = editor.view.surfaceTransparency.sendAction(editor.view.surfaceTransparency.action!, to: editor.view.surfaceTransparency.target)
        let colors = editor.draft.colors
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        model.selectAppearanceSpace(space)
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .liquidGlass, transparency: 0.88)
        await model.waitForPendingActions()
        await editor.waitUntilFinished()
        let stored = try #require(try await environment.store.spaceTheme(space))
        #expect(model.errorMessage == nil)
        #expect(stored.surface == .init(material: .liquidGlass, transparency: 0.88))
        #expect(stored.colors == colors)
        #expect(editor.isClosed && !unrelated.isClosed)
        #expect(try await environment.store.spaceTheme(other) == nil)
        #expect(!environment.themeEditors.isFrozen)
        #expect(await environment.themeEditors.finishAll())
    }

    @Test("A pending same-Space writer blocks both editor entry points and refuses a competing barrier")
    func scopedAdmission() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let other = try await environment.store.createSpace(name: "Unrelated", profileID: profile)
        let browser = try await environment.makeWindow(spaceID: space)
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let settings = BrowserSettingsWindowController(model: model)
        defer { browser.window?.close(); settings.window?.close() }
        let gate = ThemeCommitGate()
        defer { gate.release() }
        let editor = gatedEditor(space: space, profile: profile, gate: gate)
        environment.themeEditors.track(editor)
        editor.view.swatches[3].performClick(nil)
        var delivered = false
        let operation = Task {
            try await environment.themeEditors.withFinishedEditors(spaceID: space, profileID: profile) {
                delivered = true
            }
        }
        try await waitForNativeState("selective theme writer entered") { gate.entered }
        #expect(!environment.themeEditors.canBeginEditing(spaceID: space, profileID: profile))
        #expect(environment.themeEditors.canBeginEditing(spaceID: other, profileID: profile))
        #expect(!environment.themeEditors.isFrozen)
        #expect(!browser.canEditActiveSpaceTheme)
        browser.openThemeEditor(for: space, animated: false)
        settings.openThemeEditor(for: space, animated: false)
        #expect(browser.themeEditor == nil && settings.themeEditor == nil)
        await #expect(throws: BrowserSpaceThemeError.conflict) {
            try await environment.themeEditors.withFinishedEditors(spaceID: space, profileID: profile) {
                Issue.record("Competing scope must not deliver")
            }
        }
        gate.release()
        try await operation.value
        #expect(delivered)
        #expect(environment.themeEditors.canBeginEditing(spaceID: space, profileID: profile))
        #expect(!environment.themeEditors.isFrozen)
        browser.openThemeEditor(for: space, animated: false)
        #expect(browser.themeEditor != nil)
        #expect(await environment.themeEditors.finishAll())
    }

    @Test("Selection changes or finalization during the writer barrier cannot deliver a late Appearance edit", arguments: [false, true])
    func revalidateAfterWaiting(freeze: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let otherProfile = await environment.store.createProfile(name: "Other profile")
        _ = try await environment.store.createSpace(name: "Other", profileID: otherProfile)
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        model.selectAppearanceSpace(space)
        let gate = ThemeCommitGate()
        defer { gate.release() }
        let editor = gatedEditor(space: space, profile: profile, gate: gate)
        environment.themeEditors.track(editor)
        editor.view.swatches[3].performClick(nil)
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .liquidGlass)
        try await waitForNativeState("Appearance waiting for writer") { gate.entered }
        var freezing: Task<Bool, Never>?
        if freeze {
            freezing = Task { await environment.themeEditors.finishAll() }
            try await waitForNativeState("registry freeze retained") { environment.themeEditors.isFrozen }
        } else {
            model.selectProfile(otherProfile)
        }
        gate.release()
        await model.waitForPendingActions()
        await editor.waitUntilFinished()
        #expect(try await environment.store.spaceTheme(space) == nil)
        if let freezing {
            #expect(await freezing.value)
            #expect(environment.themeEditors.isFrozen)
        } else {
            #expect(model.selectedProfileID == otherProfile)
            #expect(!environment.themeEditors.isFrozen)
        }
    }

    private func gatedEditor(space: SpaceID, profile: ProfileID, gate: ThemeCommitGate) -> OrbitThemeEditorController {
        OrbitThemeEditorController(spaceID: space, profileID: profile, stored: nil,
            initial: BrowserSpaceThemePresets.default,
            commit: { _ in await gate.wait() }, replay: { _ in })
    }
}
}
