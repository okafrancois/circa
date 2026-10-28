import AppKit
import BrowserCore
import Foundation
import Testing
@testable import Orbit

/// Baseline-compatible witness for the controller's separate catalog/settings actor turns.
extension NativeWebKitTests {
@Suite("Independent Space controller adverse authority", .serialized)
@MainActor
struct SpaceSymbolControllerAdverseIndependentTests {
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    @Test("A captured controller callback must refuse a Space reassigned while its settings actor is busy")
    func reprofileDuringControllerSave() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let profile = try #require(controller.session.activeProfileID)
        let other = await environment.store.createProfile(name: "Synthetic controller adverse profile")
        let target = try await environment.store.createSpace(name: "Synthetic controller adverse target", profileID: profile)
        await environment.refreshSettingsCatalog()
        let editor = try #require(controller.makeSpaceIconEditor(for: target))
        let gate = SymbolControllerSettingsGate(), settings = environment.settings.store, blocker = SpaceID()
        let holder = Task.detached { try await settings.updateSpace(blocker) { _ in gate.hold() } }
        defer { gate.resume() }
        try await withNativeTestDeadline("Synthetic controller settings actor entered", timeout: 3) {
            while !gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        }
        editor.field.stringValue = "🧪"
        editor.complete(.alertFirstButtonReturn)
        // The callback can pass catalog admission, then wait behind the held settings actor.
        try await Task.sleep(for: .milliseconds(100))
        try await environment.store.assignSettingsSpace(target, to: other)
        gate.resume(); try await holder.value
        await editor.waitForSave()
        #expect(await environment.store.catalogSnapshot().spaces.first { $0.id == target }?.profileID == other)
        #expect(environment.settings.document.space(target).icon.isEmpty,
            "Old-profile controller callback must not mutate a reassigned Space")
        #expect(controller.window?.isVisible == false)
    }
}
}

private final class SymbolControllerSettingsGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    private let release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { didEnter } }
    func hold() { lock.withLock { didEnter = true }; _ = release.wait(timeout: .now() + 5) }
    func resume() { release.signal() }
}
