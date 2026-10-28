import Foundation
import Testing
@testable import BrowserCore

private final class OwnershipPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false
    var entered: Bool { lock.withLock { started } }
    func hold() { lock.withLock { started = true }; _ = release.wait(timeout: .now() + 8) }
    func resume() { release.signal() }
}

private final class OwnershipMutationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var completed: Bool { lock.withLock { value } }
    func finish() { lock.withLock { value = true } }
}

@Suite("Independent Space icon ownership publication recheck")
struct SpaceIconOwnershipRecheckTests {
    private func file() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("orbit-ownership-recheck-\(UUID())/settings.json")
    }

    @Test("Restored windows initialize source ownership and a different store's retirement cannot revoke it")
    func restoredWindowAndStoreIsolation() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = BrowserStore()
        let profile = await original.createProfile(name: "Synthetic restored owner")
        let space = try await original.createSpace(name: "Synthetic restored target", profileID: profile)
        let window = try await original.createWindow(activeSpaceID: space)
        let restored = try BrowserStore(restoring: await original.sessionDocument())
        let stale = try #require(original.captureSpaceSettingsAuthority(for: space, profileID: profile,
            sourceWindow: window, sourceProfile: profile))
        let independent = try #require(restored.captureSpaceSettingsAuthority(for: space, profileID: profile,
            sourceWindow: window, sourceProfile: profile))
        await original.recoverSettingsProfileRemoval(profile)
        #expect(original.captureSpaceSettingsAuthority(for: space, profileID: profile) == nil)
        let settings = try BrowserSettingsStore(destination: url)
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(space, authority: stale) { $0.iconSelection = .systemSymbol("star.fill") }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await settings.updateSpace(space, authority: independent) { $0.iconSelection = .grapheme("🇯🇵") }
        let reopened = try BrowserSettingsStore(destination: url)
        #expect(await reopened.snapshot().space(space).iconSelection == .grapheme("🇯🇵"))
    }

    @Test("Nested theme, catalog and same-profile source mutations preserve a captured target through disk publication")
    func nonOwnershipMutatorsPreserveAuthority() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let browser = BrowserStore(), settings = try BrowserSettingsStore(destination: url)
        let profile = await browser.createProfile(name: "Synthetic owner")
        let target = try await browser.createSpace(name: "Synthetic target", profileID: profile)
        let next = try await browser.createSpace(name: "Synthetic neighbor", profileID: profile)
        let window = try await browser.createWindow(activeSpaceID: target)
        let authority = try #require(browser.captureSpaceSettingsAuthority(for: target, profileID: profile,
            sourceWindow: window, sourceProfile: profile))
        try await settings.updateSpace(target) { $0.palette = .lavender }
        try await browser.renameSettingsProfile(profile, name: "Synthetic renamed owner")
        try await browser.renameSpace(target, name: "Synthetic renamed target")
        try await browser.moveSpace(target, before: nil)
        try await browser.setSpaceTheme(BrowserSpaceThemePresets.default, for: target, profileID: profile)
        try await browser.assignSettingsSpace(next, to: profile)
        try await browser.activateSpace(next, in: window)
        let context = try await browser.captureContext(in: window)
        _ = try await browser.openTab(url: URL(string: "https://example.invalid/synthetic")!, from: context, activate: true)
        _ = await browser.createProfile(name: "Synthetic unrelated owner")
        let otherWindow = try await browser.createWindow(activeSpaceID: next)
        try await browser.closeWindow(otherWindow)
        try await settings.updateSpace(target, authority: authority) { $0.iconSelection = .systemSymbol("heart.fill") }
        let reopened = try BrowserSettingsStore(destination: url)
        #expect(await reopened.snapshot().space(target).iconSelection == .systemSymbol("heart.fill"))
        #expect(await reopened.snapshot().space(target).palette == .lavender)
    }

    @Test("Ownership can change during caller preparation without deadlock and invalidates the pending file publication")
    func preparationDoesNotHoldPublicationBarrier() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let browser = BrowserStore(), settings = try BrowserSettingsStore(destination: url)
        let profile = await browser.createProfile(name: "Synthetic owner")
        let other = await browser.createProfile(name: "Synthetic other")
        let target = try await browser.createSpace(name: "Synthetic target", profileID: profile)
        _ = try await browser.createSpace(name: "Synthetic retained", profileID: profile)
        try await settings.updateSpace(target) { $0.iconSelection = .systemSymbol("heart.fill") }
        let before = await settings.snapshot(), bytes = try Data(contentsOf: url)
        let authority = try #require(browser.captureSpaceSettingsAuthority(for: target, profileID: profile))
        let gate = OwnershipPreparationGate()
        let operation = Task.detached {
            try await settings.updateSpace(target, authority: authority) { value in
                gate.hold()
                value.iconSelection = .grapheme("🧪")
            }
        }
        defer { gate.resume() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(gate.entered)
        // The settings actor is held inside the caller, rather than before actor entry.
        try await browser.assignSettingsSpace(target, to: other)
        try await browser.assignSettingsSpace(target, to: profile)
        #expect(ContinuousClock.now < deadline, "Preparation must not lock out catalog ownership changes")
        #expect(browser.captureSpaceSettingsAuthority(for: target, profileID: profile) != nil)
        authority.revoke()
        gate.resume()
        await #expect(throws: BrowserStoreError.staleContext) { try await operation.value }
        #expect(await settings.snapshot() == before)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Admitted publication excludes ownership mutation while capture and revocation remain nonblocking")
    func publicationBarrierAndShortLocks() async throws {
        let browser = BrowserStore()
        let profile = await browser.createProfile(name: "Synthetic owner")
        let other = await browser.createProfile(name: "Synthetic other")
        _ = try await browser.createSpace(name: "Synthetic retained", profileID: profile)
        let target = try await browser.createSpace(name: "Synthetic target", profileID: profile)
        let admitted = try #require(browser.captureSpaceSettingsAuthority(for: target, profileID: profile))
        let gate = OwnershipPreparationGate(), signal = OwnershipMutationSignal()
        // An internal lock witness, not a replacement for the separate actual-file tests.
        let publication = Task.detached { try admitted.publish { gate.hold() } }
        defer { gate.resume() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(gate.entered)
        let capture = try #require(browser.captureSpaceSettingsAuthority(for: target, profileID: profile))
        admitted.revoke(); capture.revoke()
        #expect(ContinuousClock.now < deadline, "Capture and UI revocation cannot wait for publication I/O")
        let mutation = Task.detached {
            try await browser.assignSettingsSpace(target, to: other)
            signal.finish()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!signal.completed)
        gate.resume()
        try await publication.value; try await mutation.value
        #expect(signal.completed)
        #expect(browser.captureSpaceSettingsAuthority(for: target, profileID: profile) == nil)
        let settings = try BrowserSettingsStore()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(target, authority: admitted) { $0.iconSelection = .none }
        }
        #expect(await settings.snapshot().spaces.isEmpty)
    }

    @Test("A pre-commit disk error keeps memory and bytes intact, consumes admission, and permits a fresh edit")
    func failedPublicationIsOneShot() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let browser = BrowserStore(), settings = try BrowserSettingsStore(destination: url)
        let profile = await browser.createProfile(name: "Synthetic owner")
        let space = try await browser.createSpace(name: "Synthetic target", profileID: profile)
        try await settings.updateSpace(space) { $0.iconSelection = .systemSymbol("star.fill"); $0.palette = .limeCitrus }
        let before = await settings.snapshot(), bytes = try Data(contentsOf: url)
        let authority = try #require(browser.captureSpaceSettingsAuthority(for: space, profileID: profile))
        let backup = url.appendingPathExtension("synthetic-backup")
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await #expect(throws: BrowserPermissionFile.Failure.unsafeFile) {
            try await settings.updateSpace(space, authority: authority) { $0.iconSelection = .none; $0.palette = .automatic }
        }
        #expect(await settings.snapshot() == before)
        #expect(try Data(contentsOf: backup) == bytes)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(space, authority: authority) { $0.iconSelection = .none }
        }
        #expect(try Data(contentsOf: url) == bytes)
        let fresh = try #require(browser.captureSpaceSettingsAuthority(for: space, profileID: profile))
        try await settings.updateSpace(space, authority: fresh) { $0.iconSelection = .grapheme("🧪") }
        #expect(try await BrowserSettingsStore(destination: url).snapshot().space(space).iconSelection == .grapheme("🧪"))
    }

    @Test("Invalid typed emptiness remains invalid in a copied candidate while explicit none and legacy clears persist")
    func typedEmptyRefusalAndClearControls() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let browser = BrowserStore(), settings = try BrowserSettingsStore(destination: url)
        let profile = await browser.createProfile(name: "Synthetic owner")
        let space = try await browser.createSpace(name: "Synthetic target", profileID: profile)
        try await settings.updateSpace(space) { $0.iconSelection = .systemSymbol("star.fill"); $0.palette = .rosePlum }
        let before = await settings.snapshot(), bytes = try Data(contentsOf: url)
        let invalid = try #require(browser.captureSpaceSettingsAuthority(for: space, profileID: profile))
        await #expect(throws: BrowserSettingsError.invalidIcon) {
            try await settings.updateSpace(space, authority: invalid) { value in
                value.iconSelection = .grapheme("")
                var copy = value
                copy.palette = .automatic
                value = copy
            }
        }
        #expect(await settings.snapshot() == before)
        #expect(try Data(contentsOf: url) == bytes)
        await #expect(throws: BrowserStoreError.staleContext) {
            try await settings.updateSpace(space, authority: invalid) { $0.iconSelection = .none }
        }
        for legacy in [false, true] {
            try await settings.updateSpace(space) { $0.iconSelection = .systemSymbol("star.fill") }
            let fresh = try #require(browser.captureSpaceSettingsAuthority(for: space, profileID: profile))
            try await settings.updateSpace(space, authority: fresh) { value in
                if legacy { value.icon = "" } else { value.iconSelection = .none }
            }
            let reopened = try BrowserSettingsStore(destination: url)
            #expect(await reopened.snapshot().space(space).iconSelection == .none)
            #expect(await reopened.snapshot().space(space).palette == .rosePlum)
        }
    }
}
