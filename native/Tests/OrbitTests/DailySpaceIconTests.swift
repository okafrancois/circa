import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Daily Space icon handoff", .serialized)
@MainActor
struct DailySpaceIconTests {
    @Test("The actual context-menu callback captures its Space and commits a grapheme through settings into the footer; clear restores a dot")
    func contextCallbackAndPersistence() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-icon-synthetic-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("settings.json")
        environment.settings = BrowserSettingsRuntime(store: try BrowserSettingsStore(destination: file))
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        var callback: SpaceID?
        controller.sidebar.footer.onEditSpaceIcon = { callback = $0 }
        let button = try #require(controller.sidebar.footer.spaceButtons.first { $0.space.id == space })
        controller.sidebar.footer.showContextMenu(for: button, present: false)
        let menu = try #require(controller.sidebar.footer.contextMenu)
        let iconIndex = try #require(menu.actions.firstIndex { $0.kind == .icon })
        #expect(menu.actions[iconIndex].enabled)
        menu.activate(iconIndex)
        #expect(callback == space)
        let editor = try #require(controller.makeSpaceIconEditor(for: space))
        editor.field.stringValue = "👩🏽‍🔬"
        editor.complete(.alertFirstButtonReturn)
        await editor.waitForSave()
        #expect(environment.settings.document.space(space).icon == "👩🏽‍🔬")
        #expect(button.settingsIcon == "👩🏽‍🔬")
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().space(space).icon == "👩🏽‍🔬")
        #expect(await environment.settings.store.snapshot().space(space).icon == "👩🏽‍🔬")
        let clear = try #require(controller.makeSpaceIconEditor(for: space))
        clear.complete(.alertThirdButtonReturn)
        await clear.waitForSave()
        #expect(environment.settings.document.space(space).icon.isEmpty && button.settingsIcon.isEmpty)
        controller.sidebar.footer.setCommandsEnabled(false)
        callback = nil
        menu.activate(iconIndex)
        #expect(callback == nil)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Invalid Unicode drafts, cancellation, queued deletion and profile changes never write a different Space")
    func cancellationAndStaleAuthority() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        let invalid = try #require(controller.makeSpaceIconEditor(for: space))
        invalid.field.stringValue = "two"
        invalid.complete(.alertFirstButtonReturn)
        await invalid.waitForSave()
        #expect(environment.settings.document.space(space).icon.isEmpty)
        let cancelled = try #require(controller.makeSpaceIconEditor(for: space))
        cancelled.field.stringValue = "🧪"
        cancelled.complete(.alertSecondButtonReturn)
        await cancelled.waitForSave()
        #expect(environment.settings.document.space(space).icon.isEmpty)
        let stale = try #require(controller.makeSpaceIconEditor(for: space))
        let profile = await environment.store.createProfile(name: "Synthetic second")
        let secondSpace = try await environment.store.createSpace(name: "Second", profileID: profile)
        controller.session.activateSpace(secondSpace)
        #expect(controller.makeSpaceIconEditor(for: space) == nil)
        stale.field.stringValue = "🧪"
        stale.complete(.alertFirstButtonReturn)
        await stale.waitForSave()
        #expect(environment.settings.document.space(space).icon.isEmpty)
        #expect(environment.settings.document.space(secondSpace).icon.isEmpty)
        let inactive = try await environment.store.createSpace(name: "Inactive", profileID: profile)
        await environment.refreshSettingsCatalog()
        let deleted = try #require(controller.makeSpaceIconEditor(for: inactive))
        try await environment.store.assignSettingsSpace(inactive, to: try #require(controller.session.catalog?.spaces.first { $0.id == space }?.profileID))
        deleted.field.stringValue = "🧪"
        deleted.complete(.alertFirstButtonReturn)
        await deleted.waitForSave()
        #expect(environment.settings.document.space(secondSpace).icon.isEmpty)
        await environment.refreshSettingsCatalog()
        let removed = try #require(controller.makeSpaceIconEditor(for: inactive))
        try await environment.removeSpaceFromSettings(inactive)
        removed.field.stringValue = "🌿"
        removed.complete(.alertFirstButtonReturn)
        await removed.waitForSave()
        #expect(environment.settings.document.space(inactive).icon.isEmpty)
        let disabled = try #require(controller.makeSpaceIconEditor(for: secondSpace))
        controller.freezeCommandsForTermination()
        #expect(controller.makeSpaceIconEditor(for: secondSpace) == nil)
        disabled.field.stringValue = "🌿"
        disabled.complete(.alertFirstButtonReturn)
        await disabled.waitForSave()
        #expect(environment.settings.document.space(secondSpace).icon.isEmpty)
    }

    @Test("Marked text cannot be applied or cleared by a sheet callback")
    func markedText() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var saved: [String] = []
        let editor = BrowserSpaceIconEditor(icon: "🧪") { saved.append($0) }
        // The alert is never shown, ordered or made key.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(editor.field)
        window.makeFirstResponder(editor.field)
        let fieldEditor = try #require(editor.field.currentEditor() as? NSTextView)
        fieldEditor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.complete(.alertFirstButtonReturn)
        editor.complete(.alertThirdButtonReturn)
        await editor.waitForSave()
        #expect(saved.isEmpty)
        fieldEditor.unmarkText()
        editor.complete(.alertSecondButtonReturn)
        editor.alert.window.close()
    }
}
}
