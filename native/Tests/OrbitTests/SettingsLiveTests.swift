import AppKit
import Darwin
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Live Settings effects")
@MainActor
struct SettingsLiveTests {
    @Test("All interaction switches default on, persist independently and apply immediately")
    func persistenceAndEffects() async throws {
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("settings-live-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let runtime = BrowserSettingsRuntime(store: try BrowserSettingsStore(destination: file))
        await runtime.refresh()
        #expect(runtime.document.interaction == .init())
        try await runtime.updateInteraction { $0.playSoundEffects = false }
        try await runtime.updateInteraction { $0.hapticFeedback = false }
        try await runtime.updateInteraction { $0.warnBeforeQuitting = false }
        let reopened = try BrowserSettingsStore(destination: file)
        let restored = await reopened.snapshot().interaction
        #expect(!restored.playSoundEffects && !restored.hapticFeedback && !restored.warnBeforeQuitting)
        #expect(runtime.feedback.preferences == restored)
        var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        old.removeValue(forKey: "interaction")
        let migrated = try JSONDecoder().decode(BrowserSettingsDocument.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(migrated.interaction == .init())
    }

    @Test("A failed settings write preserves the live sound and haptic policy")
    func failedWrite() async throws {
        let runtime = BrowserSettingsRuntime(store: .unavailable())
        await #expect(throws: BrowserSettingsError.unavailable) {
            try await runtime.updateInteraction { $0.playSoundEffects = false; $0.hapticFeedback = false }
        }
        #expect(runtime.feedback.preferences.playSoundEffects && runtime.feedback.preferences.hapticFeedback)
    }

    @Test("Turning automatic installation off keeps Sparkle checks and notifications enabled")
    func updateMode() {
        final class Target: OrbitAutomaticUpdateTarget {
            var automaticallyChecksForUpdates = false
            var automaticallyDownloadsUpdates = true
        }
        let target = Target()
        OrbitUpdater.applyAutomaticallyUpdates(false, to: target)
        #expect(target.automaticallyChecksForUpdates && !target.automaticallyDownloadsUpdates)
        OrbitUpdater.applyAutomaticallyUpdates(true, to: target)
        #expect(target.automaticallyChecksForUpdates && target.automaticallyDownloadsUpdates)
    }

    @Test("Synthetic updater switches persist using Sparkle's authority without starting any updater")
    func syntheticUpdates() throws {
        let domain = "io.github.okatech.orbit.test.settings-live.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let updater = OrbitUpdater(defaults: defaults)
        #expect(updater.automaticallyUpdates)
        updater.start(synthetic: true)
        updater.setAutomaticallyUpdates(false)
        #expect(!updater.canCheckForUpdates)
        #expect(!OrbitUpdater(defaults: defaults).automaticallyUpdates)
        // The toggle must never switch off notification checks.
        #expect(defaults.object(forKey: "SUEnableAutomaticChecks") == nil)
        updater.checkForUpdates()
        updater.setAutomaticallyUpdates(true)
        #expect(OrbitUpdater(defaults: defaults).automaticallyUpdates)
    }

    @Test("Quit warning cancels or confirms; disabled warning bypasses it; suppression persists")
    func quitWarning() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        defer { environment.autoArchive.scheduler.stop() }
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        var warnings = 0
        app.confirmQuit = { warnings += 1; return .cancel }
        #expect(!app.confirmQuitIfNeeded())
        #expect(app.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(!app.isPreparingToQuit)
        try await environment.settings.updateInteraction { $0.warnBeforeQuitting = false }
        #expect(app.confirmQuitIfNeeded())
        #expect(warnings == 2)
        try await environment.settings.updateInteraction { $0.warnBeforeQuitting = true }
        app.confirmQuit = { warnings += 1; return .quit }
        #expect(app.confirmQuitIfNeeded())
        app.confirmQuit = { .quitWithoutWarning }
        #expect(app.confirmQuitIfNeeded())
        try await app.quitPreferenceSave?.value
        #expect(!environment.settings.document.interaction.warnBeforeQuitting)
    }

    @Test("A successful user region capture sounds once; disabled, failed and empty captures are silent")
    func captureSound() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.autoArchive.scheduler.stop() }
        let context = try #require(CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let selection = BrowserCaptureSelectionView(image: image)
        var cancelled = false
        selection.onFinish = { cancelled = $0 == nil }
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        selection.keyDown(with: escape)
        #expect(cancelled)
        var sounds = 0
        environment.settings.feedback.playCaptureSound = { sounds += 1 }
        var copiedSize = NSSize.zero
        controller.capture.copyImage = { copiedSize = $0.size; return true }
        let region = CGRect(x: 0.1, y: 0.25, width: 0.5, height: 0.5)
        controller.capture.finish(image: image, normalizedRect: region)
        #expect(sounds == 1 && copiedSize == NSSize(width: 50, height: 40))
        try await environment.settings.updateInteraction { $0.playSoundEffects = false }
        controller.capture.finish(image: image, normalizedRect: region)
        #expect(sounds == 1)
        try await environment.settings.updateInteraction { $0.playSoundEffects = true }
        controller.capture.copyImage = { _ in false }
        controller.capture.finish(image: image, normalizedRect: region)
        controller.capture.finish(image: image, normalizedRect: .zero)
        #expect(sounds == 1)
    }

    @Test("Only a changed valid reorder snap emits alignment feedback, and the setting gates it live")
    func reorderHaptics() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.autoArchive.scheduler.stop() }
        var haptics = 0
        environment.settings.feedback.performAlignment = { haptics += 1 }
        let org = SyntheticOrganization()
        let tab = TabID()
        let snapshot = org.snapshot(today: [org.tab(tab)])
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        let target = RecordingDropTarget(frame: container.bounds, destination: .init(.pinned(org.spaceID)))
        container.addSubview(target.view)
        let coordinator = SidebarDropCoordinator()
        coordinator.onReorderSnap = controller.sidebar.onReorderSnap
        let payload = SidebarDragPayload(sourceWindow: UUID(), spaceID: org.spaceID, profileID: org.profileID,
            nodes: [.tab(tab)], rowCount: 1, grabOffsetX: 0)
        for _ in 0..<3 {
            coordinator.update(payload: payload, at: NSPoint(x: 30, y: 30), in: container, targets: [target], snapshot: snapshot, catalog: org.catalog)
        }
        #expect(haptics == 1)
        coordinator.clear()
        try await environment.settings.updateInteraction { $0.hapticFeedback = false }
        coordinator.update(payload: payload, at: NSPoint(x: 30, y: 30), in: container, targets: [target], snapshot: snapshot, catalog: org.catalog)
        #expect(haptics == 1)
        try await environment.settings.updateInteraction { $0.hapticFeedback = true }
        coordinator.clear()
        let invalid = SidebarDragPayload(sourceWindow: UUID(), spaceID: org.spaceID, profileID: ProfileID(),
            nodes: [.tab(tab)], rowCount: 1, grabOffsetX: 0)
        coordinator.update(payload: invalid, at: NSPoint(x: 30, y: 30), in: container, targets: [target], snapshot: snapshot, catalog: org.catalog)
        #expect(haptics == 1)
    }
}
}
