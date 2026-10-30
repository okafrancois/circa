import AppKit
import BrowserCore
import BrowserEngineConformance
@testable import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Theme lifecycle regressions", .serialized)
@MainActor
struct NativeThemeLifecycleRegressionTests {
    private typealias Environment = BrowserEnvironment<PeekSyntheticEngine>

    @Test("Immediate final save drains sidebar and Settings theme drafts", arguments: [false, true], [false, true])
    func immediateFinalSave(settingsEditor: Bool, prepares: Bool) async throws {
        for closesBrowser in [false, true] {
            try await verifyImmediateFinalSave(settingsEditor: settingsEditor, prepares: prepares, closesBrowser: closesBrowser)
        }
    }

    private func verifyImmediateFinalSave(settingsEditor: Bool, prepares: Bool, closesBrowser: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("orbit-theme-final-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let environment = try await Environment.open(engine: PeekSyntheticEngine(), sessionFile: file)
        let main = try await environment.makeWindow()
        defer { main.window?.close() }
        let space = try #require(main.session.snapshot?.activeSpaceID)
        let settings = BrowserSettingsWindowController(model: BrowserSettingsModel(environment: environment,
            profileID: main.session.activeProfileID, shortcuts: []))
        defer { settings.window?.close() }
        await settings.model.reload()
        let editor: OrbitThemeEditorController
        if settingsEditor {
            settings.openThemeEditor(for: space, animated: false)
            editor = try #require(settings.themeEditor)
        } else {
            main.openThemeEditor(for: space, animated: false)
            editor = try #require(main.themeEditor)
        }
        editor.view.swatches[7].performClick(nil)
        let draft = editor.draft
        if closesBrowser { main.window?.close() }
        if prepares { try await environment.prepareToSaveForTermination(timeout: .seconds(30)) }
        try await environment.finalize()
        let saved = try JSONDecoder().decode(BrowserSessionDocument.self, from: Data(contentsOf: file))
        #expect(saved.spaces.first(where: { $0.id == space })?.theme == draft)
        #expect(editor.isClosed, "final capture freezes the draft")
        #expect(editor.lastCommitted == draft, "final capture waits for the write")
        #expect(main.window?.isVisible == false && settings.window?.isVisible == false)
    }


    @Test("Settings theme Undo is drained before final capture and rejected once frozen", arguments: [false, true])
    func settingsUndoDuringFinalization(duringFinalization: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("orbit-theme-undo-final-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let environment = try await Environment.open(engine: PeekSyntheticEngine(), sessionFile: file)
        let (space, profile) = try await environment.initialContext.value
        let settings = BrowserSettingsWindowController(model: BrowserSettingsModel(environment: environment,
            profileID: profile, shortcuts: []))
        defer { settings.window?.close() }
        await settings.model.reload()
        settings.openThemeEditor(for: space, animated: false)
        let editor = try #require(settings.themeEditor)
        editor.view.swatches[3].performClick(nil)
        let draft = editor.draft
        editor.close(animated: false)
        await editor.waitUntilFinished()
        let manager = try #require(settings.window?.undoManager)
        try await waitForNativeState("Settings theme undo registration") { manager.canUndo }

        // Hold finalization after freezing, so the native undo target can still receive an action.
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        let gate = OrbitThemeEditorController(spaceID: space, profileID: profile, stored: nil,
            initial: BrowserSpaceThemePresets.default,
            commit: { _ in await withCheckedContinuation { release = $0 } }, replay: { _ in })
        environment.themeEditors.track(gate)
        gate.view.swatches[1].performClick(nil)
        if !duringFinalization { manager.undo() }
        let finalization = Task { try await environment.finalize() }
        try await waitForNativeState("final capture frozen with pending theme write") {
            environment.themeEditors.isFrozen && release != nil
        }
        if duringFinalization { manager.undo() }
        let continuation = release
        release = nil
        continuation?.resume()
        try await finalization.value
        let expected: BrowserSpaceTheme? = duringFinalization ? draft : nil
        #expect(try await environment.store.spaceTheme(space) == expected)
        let saved = try BrowserSessionDocument.decode(Data(contentsOf: file))
        #expect(saved.spaces.first(where: { $0.id == space })?.theme == expected)
    }

    @Test("Frozen native undo and redo keep their history after termination cancellation", arguments: [false, true], [false, true])
    func cancellationPreservesThemeHistory(settingsEditor: Bool, redo: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = Environment(engine: PeekSyntheticEngine())
        let main = try await environment.makeWindow()
        defer { main.window?.close() }
        let space = try #require(main.session.snapshot?.activeSpaceID)
        let settings = BrowserSettingsWindowController(model: BrowserSettingsModel(environment: environment,
            profileID: main.session.activeProfileID, shortcuts: []))
        defer { settings.window?.close() }
        await settings.model.reload()
        let editor: OrbitThemeEditorController
        let manager: UndoManager
        if settingsEditor {
            settings.openThemeEditor(for: space, animated: false)
            editor = try #require(settings.themeEditor)
            manager = try #require(settings.window?.undoManager)
        } else {
            main.openThemeEditor(for: space, animated: false)
            editor = try #require(main.themeEditor)
            manager = try #require(main.window?.undoManager)
        }
        editor.view.swatches[3].performClick(nil)
        let draft = editor.draft
        editor.close(animated: false)
        await editor.waitUntilFinished()
        try await waitForNativeState("theme history registered") { manager.canUndo }
        if redo {
            manager.undo()
            try await waitForNativeState("theme undone before freeze") { try await environment.store.spaceTheme(space) == nil }
        }
        #expect(await environment.themeEditors.finishAll())
        if redo { manager.redo() } else { manager.undo() }
        #expect(redo ? manager.canRedo : manager.canUndo, "the frozen attempt must not pop its entry")
        environment.terminationDidCancel()
        if redo { manager.redo() } else { manager.undo() }
        let expected: BrowserSpaceTheme? = redo ? draft : nil
        try await waitForNativeState("theme replay after termination cancellation") {
            try await environment.store.spaceTheme(space) == expected
        }
    }

    @Test("Accepted browser theme Undo and Redo drain before native replay admission freezes", arguments: [false, true])
    func queuedBrowserReplayDuringTermination(redo: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("orbit-theme-queued-undo-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let environment = try await Environment.open(engine: PeekSyntheticEngine(), sessionFile: file)
        let main = try await environment.makeWindow()
        defer { main.window?.close() }
        let window = try #require(main.window)
        let manager = try #require(window.undoManager)
        manager.groupsByEvent = false
        window.makeFirstResponder(nil)
        let space = try #require(main.session.snapshot?.activeSpaceID)
        main.session.openTab(url: URL(string: "https://theme-undo.test/")!)
        await main.session.waitForPendingCommands()
        let tab = try #require(main.session.organization?.selectedTab?.id)
        main.session.pinTabs([tab])
        await main.session.waitForPendingCommands()
        #expect(main.session.organization?.undoAction == .pinTabs)
        window.makeFirstResponder(nil)
        main.openThemeEditor(for: space, animated: false)
        let editor = try #require(main.themeEditor)
        editor.view.swatches[3].performClick(nil)
        let draft = editor.draft
        editor.close(animated: false)
        await editor.waitUntilFinished()
        let router = main.sidebar.undoRouter
        #expect(router.nextSource(redo: false) == .window)
        if redo {
            router.undo(nil)
            await router.waitForPendingCommands()
            try await waitForNativeState("theme undone before queued Redo") {
                try await environment.store.spaceTheme(space) == nil
            }
        }

        // Reserve the real router input behind a suspended session command, as at quit receipt.
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        main.session.enqueue { _ in await withCheckedContinuation { release = $0 } }
        try await waitForNativeState("session command gate installed") { release != nil }
        if redo { router.redo(nil) } else { router.undo(nil) }
        let preparation = Task { try await environment.prepareToSaveForTermination(timeout: .seconds(30)) }
        try await waitForNativeState("browser input frozen while accepted replay is queued") {
            !main.acceptsCommands
        }
        let continuation = release
        release = nil
        continuation?.resume()
        try await preparation.value
        let expected: BrowserSpaceTheme? = redo ? draft : nil
        #expect(try await environment.store.spaceTheme(space) == expected)
        var nextSource: SidebarUndoRouter.Source?
        main.performAcceptedCommand { nextSource = router.nextSource(redo: false) }
        #expect(nextSource == (redo ? .window : .organization))
        try await environment.finalize()
        let saved = try BrowserSessionDocument.decode(Data(contentsOf: file))
        #expect(saved.spaces.first(where: { $0.id == space })?.theme == expected)
    }

    @Test("Browser address and navigation controls consume the contrast-adjusted Space accent", arguments: [false, true])
    func browserChromeContrastRoles(isDark: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = Environment(engine: PeekSyntheticEngine())
        let main = try await environment.makeWindow()
        defer { main.window?.close() }
        let space = try #require(main.session.snapshot?.activeSpaceID)
        let profile = try #require(main.session.activeProfileID)
        var theme = try #require(BrowserSpaceThemePresets.theme(family: BrowserSpaceThemePresets.greyscale, index: 7))
        theme.mode = isDark ? .dark : .light
        try await environment.store.setSpaceTheme(theme, for: space, profileID: profile)
        let painted = OrbitSpaceThemes.rendered(theme)
        try await waitForNativeState("theme applied to browser chrome") { main.windowShell.theme == painted }
        let accent = OrbitSpaceThemes.accent(for: painted)
        let addressAccent = main.sidebar.addressContainer.effectiveAccent
        #expect(main.addressField.textColor == addressAccent.sidebarText)
        #expect(main.addressField.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == addressAccent.sidebarSecondaryText)
        let toolbar = main.sidebar.navigationContainer
        let buttons = toolbar.buttons + (toolbar.overflowButton.map { [$0] } ?? [])
        #expect(buttons.count >= 4)
        let toolbarAccent = OrbitSpaceThemes.accent(accent, over: [], iconHover: OrbitTokens.Color.State.standaloneButton)
        for button in buttons {
            if let glyph = button as? OrbitGlyphButton { #expect(glyph.tint == toolbarAccent.icon) }
            else { #expect(button.contentTintColor == toolbarAccent.icon) }
        }
        #expect(main.window?.isVisible == false)
    }

    @Test("Little Circa keeps its dark window surfaces in dark, light and automatic Space modes")
    func quickWindowAppearance() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = Environment(engine: PeekSyntheticEngine())
        let (space, profile) = try await environment.initialContext.value
        var theme = BrowserSpaceThemePresets.default
        theme.mode = .dark
        try await environment.store.setSpaceTheme(theme, for: space, profileID: profile)
        let little = try await environment.makeQuickWindow(spaceID: space, startLoading: false)
        defer { environment.retireQuickWindows() }
        #expect(little.window?.appearance?.name == .darkAqua)
        theme.mode = .light
        little.applyPreferences(searchEngine: .google, theme: OrbitSpaceThemes.rendered(theme))
        #expect(little.window?.appearance?.name == .darkAqua)
        theme.mode = .automatic
        little.applyPreferences(searchEngine: .google, theme: OrbitSpaceThemes.rendered(theme))
        #expect(little.window?.appearance?.name == .darkAqua)
        #expect(little.window?.isVisible == false)
    }

    @Test("Settings edits repaint Little Circa without a browser window")
    func settingsOnlyPropagation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = Environment(engine: PeekSyntheticEngine())
        let (space, profile) = try await environment.initialContext.value
        let little = try await environment.makeQuickWindow(spaceID: space, startLoading: false)
        defer { environment.retireQuickWindows() }
        let settings = BrowserSettingsWindowController(model: BrowserSettingsModel(environment: environment,
            profileID: profile, shortcuts: []))
        defer { settings.window?.close() }
        await settings.model.reload()
        settings.openThemeEditor(for: space, animated: false)
        let editor = try #require(settings.themeEditor)
        editor.view.swatches[3].performClick(nil)
        editor.view.modeButtons[2].performClick(nil)
        let draft = editor.draft
        editor.close(animated: false)
        await editor.waitUntilFinished()
        try await waitForNativeState("Settings theme reaches Little Circa") {
            little.toolbar.fill.theme == OrbitSpaceThemes.rendered(draft)
        }
        #expect(little.window?.appearance?.name == .darkAqua)
        #expect(environment.liveControllers.isEmpty)
    }

    @Test("Store changes propagate automatically to browser windows and surviving Little Circas")
    func automaticPropagation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = Environment(engine: PeekSyntheticEngine())
        let main = try await environment.makeWindow()
        let space = try #require(main.session.snapshot?.activeSpaceID)
        let profile = try #require(main.session.activeProfileID)
        let other = try await environment.makeWindow(spaceID: space)
        defer { main.window?.close(); other.window?.close(); environment.retireQuickWindows() }
        let little = try await environment.makeQuickWindow(spaceID: space, startLoading: false)
        let secondLittle = try await environment.makeQuickWindow(spaceID: space, startLoading: false)
        let first = try #require(BrowserSpaceThemePresets.theme(family: BrowserSpaceThemePresets.brand, index: 3))
        try await environment.store.setSpaceTheme(first, for: space, profileID: profile)
        try await waitForNativeState("automatic theme propagation with browser windows") {
            [main, other].allSatisfy { $0.windowShell.theme == OrbitSpaceThemes.rendered(first) }
                && [little, secondLittle].allSatisfy { $0.toolbar.fill.theme == OrbitSpaceThemes.rendered(first) }
        }
        main.window?.close()
        other.window?.close()
        let second = try #require(BrowserSpaceThemePresets.theme(family: BrowserSpaceThemePresets.greyscale, index: 7))
        try await environment.store.setSpaceTheme(second, for: space, profileID: profile)
        try await waitForNativeState("automatic theme propagation after browser windows close") {
            [little, secondLittle].allSatisfy { $0.toolbar.fill.theme == OrbitSpaceThemes.rendered(second) }
        }
    }
}
}
