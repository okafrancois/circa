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



    private func gatedEditor(space: SpaceID, profile: ProfileID, gate: ThemeCommitGate) -> OrbitThemeEditorController {
        OrbitThemeEditorController(spaceID: space, profileID: profile, stored: nil,
            initial: BrowserSpaceThemePresets.default,
            commit: { _ in await gate.wait() }, replay: { _ in })
    }
}
}
