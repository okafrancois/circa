import AppKit
import BrowserCore
import BrowserShell
import Foundation
import Testing
@testable import Orbit

private final class SpaceIconPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { started } }
    func hold() { lock.withLock { started = true }; _ = semaphore.wait(timeout: .now() + 5) }
    func resume() { semaphore.signal() }
}

extension NativeWebKitTests {
@Suite("Space icon publication lifecycle", .serialized)
@MainActor
struct SpaceIconPublicationLifecycleTests {
    enum Revocation: CaseIterable, Sendable { case settingsSelectionABA, settingsTargetABA, controllerSourceABA, controllerClose }
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    @Test("Edits awaiting the settings actor lose revoked selection, target or window authority", arguments: Revocation.allCases)
    func revokedWhileWaiting(_ reason: Revocation) async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let profile = try #require(controller.session.activeProfileID)
        let other = await environment.store.createProfile(name: "Synthetic other")
        let foreign = try await environment.store.createSpace(name: "Synthetic foreign", profileID: other)
        let target = try await environment.store.createSpace(name: "Synthetic target", profileID: profile)
        await environment.refreshSettingsCatalog()
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let editor = try #require(controller.makeSpaceIconEditor(for: target))
        let gate = SpaceIconPublicationGate(), settings = environment.settings.store, blocker = SpaceID()
        let holder = Task.detached { try await settings.updateSpace(blocker) { _ in gate.hold() } }
        defer { gate.resume() }
        try await withNativeTestDeadline("Synthetic icon settings gate", timeout: 3) {
            while !gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        }
        switch reason {
        case .settingsSelectionABA, .settingsTargetABA:
            model.queueSpaceIconEdit(spaceID: target, profileID: profile, icon: .systemSymbol("star.fill"))
        case .controllerSourceABA, .controllerClose:
            editor.field.stringValue = "🧪"; editor.complete(.alertFirstButtonReturn)
        }
        try await Task.sleep(for: .milliseconds(100))
        switch reason {
        case .settingsSelectionABA:
            model.selectProfile(other); model.selectProfile(profile)
        case .settingsTargetABA:
            try await environment.store.assignSettingsSpace(target, to: other)
            try await environment.store.assignSettingsSpace(target, to: profile)
        case .controllerSourceABA:
            let window = try #require(controller.session.snapshot?.id)
            let original = try #require(controller.session.snapshot?.activeSpaceID)
            try await environment.store.activateSpace(foreign, in: window)
            try await environment.store.activateSpace(original, in: window)
        case .controllerClose:
            controller.session.close()
        }
        gate.resume(); try await holder.value
        await model.waitForPendingActions(); await editor.waitForSave()
        await controller.session.waitForPendingCommands()
        #expect(await settings.snapshot().space(target).iconSelection == .none)
        #expect(controller.window?.isVisible == false)
    }

    @Test("An accepted controller save participates in command draining and commits only once")
    func acceptedSaveDrains() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let target = try #require(controller.session.snapshot?.activeSpaceID)
        let editor = try #require(controller.makeSpaceIconEditor(for: target))
        let gate = SpaceIconPublicationGate(), settings = environment.settings.store, blocker = SpaceID()
        let holder = Task.detached { try await settings.updateSpace(blocker) { _ in gate.hold() } }
        defer { gate.resume() }
        try await withNativeTestDeadline("Synthetic accepted icon gate", timeout: 3) {
            while !gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        }
        editor.field.stringValue = "🧪"; editor.complete(.alertFirstButtonReturn)
        try await withNativeTestDeadline("Accepted icon joins the window queue", timeout: 3) {
            while !controller.session.hasPendingCommands { await Task.yield() }
        }
        controller.freezeCommandsForTermination()
        gate.resume(); try await holder.value
        await controller.session.waitForPendingCommands(); await editor.waitForSave()
        #expect(await settings.snapshot().space(target).iconSelection == .grapheme("🧪"))
        editor.field.stringValue = "⭐️"; editor.complete(.alertFirstButtonReturn)
        await editor.waitForSave()
        #expect(await settings.snapshot().space(target).iconSelection == .grapheme("🧪"))
        #expect(controller.window?.isVisible == false)
    }
}
}
