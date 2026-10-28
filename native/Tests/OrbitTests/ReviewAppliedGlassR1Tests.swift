import AppKit
import BrowserCore
import BrowserEngineConformance
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Independent applied glass R1 review", .serialized)
@MainActor
struct ReviewAppliedGlassR1Tests {
    @Test("Appearance updates every same-Space window and leaves another profile untouched")
    func multiWindowAndFrozenQueue() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let otherProfile = await environment.store.createProfile(name: "Other")
        let otherSpace = try await environment.store.createSpace(name: "Blue", profileID: otherProfile)
        let first = try await environment.makeWindow(spaceID: space)
        let second = try await environment.makeWindow(spaceID: space)
        let third = try await environment.makeWindow(spaceID: otherSpace)
        defer { first.window?.close(); second.window?.close(); third.window?.close() }
        let untouched = third.windowShell.theme
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        model.selectAppearanceSpace(space)
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .liquidGlass, transparency: 0.81)
        await model.waitForPendingActions()
        #expect(model.errorMessage == nil)
        for controller in [first, second] {
            #expect(controller.windowShell.theme.surface == .init(material: .liquidGlass, transparency: 0.81))
            #expect(controller.window?.isVisible == false)
            #expect(controller.window?.alphaValue == 1)
        }
        #expect(third.windowShell.theme == untouched)
        #expect(try await environment.store.spaceTheme(otherSpace) == nil)
        let before = await environment.store.sessionDocument()
        #expect(await environment.themeEditors.finishAll())
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .solid)
        await model.waitForPendingActions()
        #expect(await environment.store.sessionDocument() == before)
        #expect(model.errorMessage != nil)
        environment.themeEditors.thaw()
    }

    @Test("Unavailable settings, queued reassignment and actual Space deletion reject captured edits")
    func unavailableAndRevokedAuthority() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let otherProfile = await environment.store.createProfile(name: "Other")
        let spare = try await environment.store.createSpace(name: "Spare", profileID: profile)
        environment.settings = BrowserSettingsRuntime(store: .unavailable())
        let unavailable = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await unavailable.reload()
        unavailable.selectAppearanceSpace(space)
        let before = await environment.store.sessionDocument()
        unavailable.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .liquidGlass)
        await unavailable.waitForPendingActions()
        #expect(unavailable.errorMessage != nil)
        #expect(await environment.store.sessionDocument() == before)
        environment.settings = BrowserSettingsRuntime(store: try BrowserSettingsStore())
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        model.selectAppearanceSpace(space)
        model.perform { try await environment.store.assignSettingsSpace(space, to: otherProfile) }
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, transparency: 0.7)
        await model.waitForPendingActions()
        #expect(model.errorMessage != nil)
        #expect(try await environment.store.spaceTheme(space) == nil)
        #expect(try await environment.store.spaceTheme(spare) == nil)
        model.selectAppearanceSpace(spare)
        model.perform { try await environment.store.removeSettingsSpace(spare, expectedProfileID: profile) }
        model.queueAppearanceSurfaceEdit(spaceID: spare, profileID: profile, material: .solid)
        await model.waitForPendingActions()
        #expect(model.errorMessage != nil)
        #expect(!(await environment.store.catalogSnapshot()).spaces.contains { $0.id == spare })
        #expect(try await environment.store.spaceTheme(space) == nil)
    }

    @Test("Escape commits a surface edit as one undoable session; undo and redo restore optional policy")
    func surfaceDismissUndoRedo() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, _) = try await environment.initialContext.value
        let controller = try await environment.makeWindow(spaceID: space)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        controller.openThemeEditor(for: space, animated: false)
        let editor = try #require(controller.themeEditor)
        editor.view.surfaceMaterial.selectItem(at: BrowserThemeSurface.Material.allCases.firstIndex(of: .liquidGlass)!)
        _ = editor.view.surfaceMaterial.sendAction(editor.view.surfaceMaterial.action!, to: editor.view.surfaceMaterial.target)
        editor.view.surfaceTransparency.doubleValue = 0.73
        _ = editor.view.surfaceTransparency.sendAction(editor.view.surfaceTransparency.action!, to: editor.view.surfaceTransparency.target)
        let draft = editor.draft
        #expect(controller.windowShell.theme.surface == .init(material: .liquidGlass, transparency: 0.73))
        // Existing editor contract: Escape dismisses and saves; it is not a discard command.
        editor.panel?.cancelOperation(nil)
        await editor.waitUntilFinished()
        #expect(editor.isClosed && editor.registeredChange?.before == nil)
        #expect(try await environment.store.spaceTheme(space) == draft)
        let manager = try #require(window.undoManager)
        try await waitForNativeState("surface undo registered") { manager.canUndo }
        manager.undo()
        try await waitForNativeState("surface undo restored absence") { try await environment.store.spaceTheme(space) == nil }
        #expect(manager.canRedo)
        manager.redo()
        try await waitForNativeState("surface redo restored policy") { try await environment.store.spaceTheme(space) == draft }
        #expect(window.isVisible == false)
    }

    @Test("Closing a throttled color editor must preserve a newer Appearance surface edit")
    func closingColorEditorMustNotEraseAppliedSurface() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let controller = try await environment.makeWindow(spaceID: space)
        defer { controller.window?.close() }
        controller.openThemeEditor(for: space, animated: false)
        let editor = try #require(controller.themeEditor)
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        model.selectAppearanceSpace(space)
        editor.view.swatches[3].performClick(nil)
        // Let the real 120 ms throttle begin, then simulate resign-key dismissal.
        try await Task.sleep(for: .milliseconds(10))
        editor.close(animated: false)
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .liquidGlass, transparency: 0.88)
        await model.waitForPendingActions()
        let applied = BrowserThemeSurface(material: .liquidGlass, transparency: 0.88)
        #expect(try await environment.store.spaceTheme(space)?.surface == applied)
        await editor.waitUntilFinished()
        await controller.session.waitForPendingCommands()
        let finalSurface = try await environment.store.spaceTheme(space)?.surface
        #expect(finalSurface == applied,
                "An older color draft must not silently erase a newer applied material")
    }
}
}
