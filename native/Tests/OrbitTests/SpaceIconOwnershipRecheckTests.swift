import AppKit
import BrowserCore
import Foundation
import Testing
@testable import Orbit

private final class OwnershipSettingsActorGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false
    var entered: Bool { lock.withLock { started } }
    func hold() { lock.withLock { started = true }; _ = release.wait(timeout: .now() + 8) }
    func resume() { release.signal() }
}

extension NativeWebKitTests {
@Suite("Independent hidden Space icon ownership recheck", .serialized)
@MainActor
struct SpaceIconOwnershipUIRecheckTests {
    enum Entry: CaseIterable, Sendable { case settings, controller }
    enum Change: CaseIterable, Sendable {
        case targetABA, archiveRestore, sourceABA, sourceClose, profileSelectionABA, appearanceSelectionABA, sameProfileNavigation
    }
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    @Test("Actual Settings and controller callbacks retain only their own authority through settings file publication",
          arguments: Entry.allCases, Change.allCases)
    func heldActorFilePublication(_ entry: Entry, _ change: Change) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("orbit-ownership-ui-recheck-\(UUID())", isDirectory: true)
        let file = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let settings = try BrowserSettingsStore(destination: file)
        environment.settings = BrowserSettingsRuntime(store: settings)
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let profile = try #require(controller.session.activeProfileID)
        let source = try #require(controller.session.snapshot?.activeSpaceID)
        let window = try #require(controller.session.snapshot?.id)
        let other = await environment.store.createProfile(name: "Synthetic foreign owner")
        let foreign = try await environment.store.createSpace(name: "Synthetic foreign source", profileID: other)
        let neighbor = try await environment.store.createSpace(name: "Synthetic same owner", profileID: profile)
        let target = try await environment.store.createSpace(name: "Synthetic immutable target", profileID: profile)
        await environment.refreshSettingsCatalog()
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        model.selectAppearanceSpace(target)
        let editor = try #require(controller.makeSpaceIconEditor(for: target))
        let blocker = SpaceID()
        try await settings.updateSpace(target) { $0.iconSelection = .systemSymbol("heart.fill"); $0.palette = .lavender }
        try await settings.updateSpace(foreign) { $0.iconSelection = .grapheme("🇯🇵") }
        try await settings.updateSpace(blocker) { _ in }
        await environment.settings.refresh()
        let before = await settings.snapshot(), bytes = try Data(contentsOf: file)
        let gate = OwnershipSettingsActorGate()
        let holder = Task.detached { try await settings.updateSpace(blocker) { _ in gate.hold() } }
        defer { gate.resume() }
        try await withNativeTestDeadline("Independent held settings actor", timeout: 3) {
            while !gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        }
        switch entry {
        case .settings:
            model.queueSpaceIconEdit(spaceID: target, profileID: profile, icon: .systemSymbol("star.fill"))
        case .controller:
            editor.field.stringValue = "🧪"
            editor.complete(.alertFirstButtonReturn)
            try await withNativeTestDeadline("Independent controller command admission", timeout: 3) {
                while !controller.session.hasPendingCommands { await Task.yield() }
            }
        }
        // Public Settings has no actor-entry hook. Preserve an explicit scheduling interval;
        // identity is captured synchronously, and every adverse mutation below is awaited.
        try await Task.sleep(for: .milliseconds(100))
        switch change {
        case .targetABA:
            try await environment.store.assignSettingsSpace(target, to: other)
            try await environment.store.assignSettingsSpace(target, to: profile)
        case .archiveRestore:
            try await environment.store.removeSettingsSpace(target, expectedProfileID: profile)
            try await environment.store.restoreSettingsSpace(target, expectedProfileID: profile)
        case .sourceABA:
            try await environment.store.activateSpace(foreign, in: window)
            try await environment.store.activateSpace(source, in: window)
        case .sourceClose:
            controller.session.close()
        case .profileSelectionABA:
            model.selectProfile(other); model.selectProfile(profile)
        case .appearanceSelectionABA:
            model.selectAppearanceSpace(neighbor); model.selectAppearanceSpace(target)
        case .sameProfileNavigation:
            try await environment.store.activateSpace(neighbor, in: window)
        }
        gate.resume(); try await holder.value
        await model.waitForPendingActions(); await editor.waitForSave()
        await controller.session.waitForPendingCommands()
        let rejected = change == .targetABA || change == .archiveRestore
            || (entry == .controller && (change == .sourceABA || change == .sourceClose))
            || (entry == .settings && (change == .profileSelectionABA || change == .appearanceSelectionABA))
        let after = await settings.snapshot()
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot() == after)
        if rejected {
            #expect(after == before)
            #expect(try Data(contentsOf: file) == bytes)
        } else {
            let expected: BrowserSpaceIcon = entry == .settings ? .systemSymbol("star.fill") : .grapheme("🧪")
            #expect(after.space(target).iconSelection == expected)
            #expect(after.space(target).palette == .lavender)
            #expect(after.space(foreign) == before.space(foreign))
        }
        // A fresh restored target is usable even when the earlier target epoch was revoked.
        if change == .targetABA || change == .archiveRestore {
            let fresh = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
            fresh.queueSpaceIconEdit(spaceID: target, profileID: profile, icon: .none)
            await fresh.waitForPendingActions()
            #expect(try await BrowserSettingsStore(destination: file).snapshot().space(target).iconSelection == .none)
        }
        #expect(controller.window?.isVisible == false)
        #expect(!NSApplication.shared.isActive)
    }

    @Test("A symbol picker save accepted before Quit joins the drain and reopens from the actual file")
    func pickerSaveDrainsToDisk() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("orbit-picker-drain-recheck-\(UUID())", isDirectory: true)
        let file = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let settings = try BrowserSettingsStore(destination: file)
        environment.settings = BrowserSettingsRuntime(store: settings)
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let target = try #require(controller.session.snapshot?.activeSpaceID)
        let picker = try #require(controller.makeSpaceIconPicker(for: target))
        picker.loadViewIfNeeded()
        picker.modes.selectedSegment = SpaceIconPicker.Mode.icons.rawValue
        #expect(picker.modes.sendAction(picker.modes.action, to: picker.modes.target))
        let blocker = SpaceID(), gate = OwnershipSettingsActorGate()
        let holder = Task.detached { try await settings.updateSpace(blocker) { _ in gate.hold() } }
        defer { gate.resume() }
        try await withNativeTestDeadline("Independent picker settings actor", timeout: 3) {
            while !gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        }
        picker.choose(.systemSymbol("star.fill"))
        try await withNativeTestDeadline("Independent picker command joins drain", timeout: 3) {
            while !controller.session.hasPendingCommands { await Task.yield() }
        }
        controller.freezeCommandsForTermination()
        gate.resume(); try await holder.value
        await controller.session.waitForPendingCommands()
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().space(target).iconSelection == .systemSymbol("star.fill"))
        picker.choose(.systemSymbol("heart.fill"))
        await controller.session.waitForPendingCommands()
        #expect(await settings.snapshot().space(target).iconSelection == .systemSymbol("star.fill"))
        #expect(controller.window?.isVisible == false && !NSApplication.shared.isActive)
    }
}
}
