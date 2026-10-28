import AppKit
import BrowserCore
import BrowserEngineConformance
import Testing
@testable import Orbit
@testable import BrowserShell

@MainActor
private final class ReviewOrderingGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        let saved = continuation
        continuation = nil
        saved?.resume()
    }
}

extension NativeWebKitTests {
@Suite("Independent glass ordering R2", .serialized)
@MainActor
struct ReviewGlassOrderingR2Tests {
    @Test("Settings-owned closure appends reload behind Appearance without a queue cycle")
    func settingsOwnedEditorAndTerminationDrain() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let settings = BrowserSettingsWindowController(model: model)
        defer { settings.window?.close() }
        settings.openThemeEditor(for: space, animated: false)
        let editor = try #require(settings.themeEditor)
        editor.view.swatches[3].performClick(nil)
        let colors = editor.draft.colors
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .liquidGlass, transparency: 0.88)
        // Production quit drains all accepted Settings work, including the reentrant onClosed reload.
        try await model.suspendForTermination(timeout: .seconds(20))
        #expect(!model.isBusy && !model.acceptsActions)
        #expect(settings.themeEditor == nil && editor.isClosed)
        #expect(model.errorMessage == nil)
        #expect(try await environment.store.spaceTheme(space)?.colors == colors)
        #expect(try await environment.store.spaceTheme(space)?.surface == .init(material: .liquidGlass, transparency: 0.88))
        try await environment.prepareToSaveForTermination(timeout: .seconds(20))
        #expect(environment.themeEditors.isFrozen)
        environment.terminationDidCancel()
        model.resumeAfterCancelledTermination()
        #expect(environment.themeEditors.canBeginEditing(spaceID: space, profileID: profile))
    }

    @Test("Two Settings models expose a competing lease failure and can retry without losing colors")
    func concurrentModels() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let first = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        let second = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await first.reload(); await second.reload()
        let gate = ReviewOrderingGate()
        defer { gate.release() }
        let editor = OrbitThemeEditorController(spaceID: space, profileID: profile, stored: nil,
            initial: BrowserSpaceThemePresets.default,
            commit: { theme in
                await gate.wait()
                try await environment.store.setSpaceTheme(theme, for: space, profileID: profile)
            }, replay: { _ in })
        environment.themeEditors.track(editor)
        editor.view.swatches[3].performClick(nil)
        let colors = editor.draft.colors
        first.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .liquidGlass, transparency: 0.88)
        try await waitForNativeState("first model holds scoped lease") { gate.entered }
        second.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .solid)
        try await waitForNativeState("competing model reports visible failure") { !second.isBusy && second.errorMessage != nil }
        #expect(try await environment.store.spaceTheme(space) == nil)
        gate.release()
        try await waitForNativeState("first model settles") { !first.isBusy }
        #expect(first.errorMessage == nil)
        #expect(try await environment.store.spaceTheme(space)?.surface == .init(material: .liquidGlass, transparency: 0.88))
        second.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, transparency: 0.63)
        try await waitForNativeState("retry settles") { !second.isBusy }
        #expect(second.errorMessage == nil)
        #expect(try await environment.store.spaceTheme(space)?.colors == colors)
        #expect(try await environment.store.spaceTheme(space)?.surface == .init(material: .liquidGlass, transparency: 0.63))
    }

    @Test("Closed finishing editor remains retained, failed commit releases only its scope")
    func retainedFailureAndReentrantClose() async throws {
        let registry = OrbitThemeEditorRegistry()
        let space = SpaceID(), other = SpaceID(), profile = ProfileID()
        let gate = ReviewOrderingGate()
        defer { gate.release() }
        var closed = false
        var enteredOperation = false
        var editor: OrbitThemeEditorController? = OrbitThemeEditorController(spaceID: space, profileID: profile,
            stored: nil, initial: BrowserSpaceThemePresets.default,
            commit: { _ in await gate.wait(); throw BrowserSpaceThemeError.conflict }, replay: { _ in })
        weak let retained = editor
        editor?.onClosed = {
            closed = true
            #expect(!registry.canBeginEditing(spaceID: space, profileID: profile))
            #expect(registry.canBeginEditing(spaceID: other, profileID: profile))
        }
        registry.track(try #require(editor))
        editor?.view.swatches[3].performClick(nil)
        editor?.close(animated: false)
        editor = nil
        try await waitForNativeState("closed writer still pending") { gate.entered }
        #expect(retained?.isClosed == true)
        let operation = Task {
            try await registry.withFinishedEditors(spaceID: space, profileID: profile) { enteredOperation = true }
        }
        try await waitForNativeState("closed writer reserved") { !registry.canBeginEditing(spaceID: space, profileID: profile) }
        gate.release()
        await #expect(throws: BrowserSpaceThemeError.conflict) { try await operation.value }
        #expect(closed && !enteredOperation)
        #expect(registry.canBeginEditing(spaceID: space, profileID: profile))
        #expect(!registry.isFrozen)
    }

    @Test("Previously accepted replay drains before surface mutation and stale Undo stays guarded")
    func replayOrderingAndCAS() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let registry = OrbitThemeEditorRegistry()
        let gate = ReviewOrderingGate()
        defer { gate.release() }
        let original = BrowserSpaceThemePresets.default
        let change = try await store.setSpaceTheme(original, for: space, profileID: profile)
        #expect(registry.enqueueReplay {
            await gate.wait()
            try await store.applySpaceThemeChange(change.inverse)
        })
        try await waitForNativeState("accepted replay pending") { gate.entered }
        var applied = false
        let barrier = Task {
            try await registry.withFinishedEditors(spaceID: space, profileID: profile) {
                #expect(try await store.spaceTheme(space) == nil)
                try await store.setSpaceThemeSurface(for: space, profileID: profile, material: .liquidGlass, transparency: 0.88)
                applied = true
            }
        }
        try await waitForNativeState("replay is covered by scope") { !registry.canBeginEditing(spaceID: space, profileID: profile) }
        #expect(!applied)
        gate.release()
        try await barrier.value
        let surface = try await store.spaceTheme(space)
        await #expect(throws: BrowserSpaceThemeError.conflict) { try await store.applySpaceThemeChange(change) }
        #expect(try await store.spaceTheme(space) == surface)
        #expect(applied && registry.canBeginEditing(spaceID: space, profileID: profile))
    }

    @Test("Cancellation retains the reservation until accepted work settles and never thaws a global freeze")
    func cancellationAndGlobalFreeze() async throws {
        let registry = OrbitThemeEditorRegistry()
        let space = SpaceID(), other = SpaceID(), profile = ProfileID()
        let gate = ReviewOrderingGate()
        defer { gate.release() }
        let task = Task {
            try await registry.withFinishedEditors(spaceID: space, profileID: profile) {
                await gate.wait()
                try Task.checkCancellation()
            }
        }
        try await waitForNativeState("operation holds reservation") { gate.entered }
        task.cancel()
        #expect(!registry.canBeginEditing(spaceID: space, profileID: profile))
        #expect(registry.canBeginEditing(spaceID: other, profileID: profile))
        #expect(await registry.finishAll())
        #expect(!registry.enqueueReplay { Issue.record("Frozen replay must not run") })
        gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(registry.isFrozen)
        #expect(!registry.canBeginEditing(spaceID: space, profileID: profile))
        registry.thaw()
        #expect(registry.canBeginEditing(spaceID: space, profileID: profile))
        #expect(registry.canBeginEditing(spaceID: other, profileID: profile))
    }

    @Test("New Settings editor admitted during Appearance catalog refresh must retain the applied surface")
    func newEditorDuringCatalogRefreshMustPreserveSurface() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let browser = try await environment.makeWindow(spaceID: space)
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let settings = BrowserSettingsWindowController(model: model)
        defer { browser.window?.close(); settings.window?.close() }
        let gate = ReviewOrderingGate()
        defer { gate.release() }
        // An accepted browser command delays the catalog refresh, not the actor's field mutation.
        browser.session.enqueue { _ in await gate.wait() }
        try await waitForNativeState("browser command pending") { gate.entered }
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .liquidGlass, transparency: 0.88)
        let applied = BrowserThemeSurface(material: .liquidGlass, transparency: 0.88)
        try await waitForNativeState("surface committed before catalog refresh") {
            try await environment.store.spaceTheme(space)?.surface == applied
        }
        #expect(model.isBusy)
        #expect(model.errorMessage == nil)
        #expect(model.catalog.spaces.first(where: { $0.id == space })?.theme == nil)
        #expect(!environment.themeEditors.canBeginEditing(spaceID: space, profileID: profile))
        settings.openThemeEditor(for: space, animated: false)
        #expect(settings.themeEditor == nil)
        gate.release()
        try await waitForNativeState("Appearance publishes fresh editor inputs") { !model.isBusy }
        #expect(environment.themeEditors.canBeginEditing(spaceID: space, profileID: profile))
        settings.openThemeEditor(for: space, animated: false)
        let editor = try #require(settings.themeEditor)
        #expect(editor.original?.surface == applied)
        editor.view.swatches[3].performClick(nil)
        let colors = editor.draft.colors
        editor.close(animated: false)
        await editor.waitUntilFinished()
        #expect(try await environment.store.spaceTheme(space)?.colors == colors)
        gate.release()
        try await waitForNativeState("Appearance and reentrant reload settle") { !model.isBusy }
        let finalSurface = try await environment.store.spaceTheme(space)?.surface
        #expect(finalSurface == applied,
                "An editor admitted after the lease must not restore its stale catalog's absent surface")
    }

    @Test("Reassignment while an old owner finishes rejects its write and preserves the new owner's theme")
    func newOwnerDuringBarrier() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let newProfile = await environment.store.createProfile(name: "New owner")
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let gate = ReviewOrderingGate()
        defer { gate.release() }
        let editor = OrbitThemeEditorController(spaceID: space, profileID: profile, stored: nil,
            initial: BrowserSpaceThemePresets.default,
            commit: { theme in
                await gate.wait()
                try await environment.store.setSpaceTheme(theme, for: space, profileID: profile)
            }, replay: { _ in })
        environment.themeEditors.track(editor)
        editor.view.swatches[3].performClick(nil)
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .liquidGlass)
        try await waitForNativeState("old owner waiting") { gate.entered }
        try await environment.store.assignSettingsSpace(space, to: newProfile)
        var newer = BrowserSpaceThemePresets.default
        newer.surface = .init(material: .frosted, transparency: 0.31)
        try await environment.store.setSpaceTheme(newer, for: space, profileID: newProfile)
        gate.release()
        try await waitForNativeState("old owner action rejected") { !model.isBusy }
        #expect(model.errorMessage != nil && editor.failed)
        #expect(try await environment.store.spaceTheme(space) == newer)
        #expect(environment.themeEditors.canBeginEditing(spaceID: space, profileID: profile))
        #expect(environment.themeEditors.canBeginEditing(spaceID: space, profileID: newProfile))
    }
}
}
