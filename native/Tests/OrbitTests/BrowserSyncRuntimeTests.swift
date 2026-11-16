import Foundation
import Testing
import BrowserCore
import CloudKit
@testable import Orbit

@MainActor
struct BrowserSyncRuntimeTests {
    @Test("Disabled sync has no task; enable cycles restart after disable and cancelled termination")
    func lifecycle() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var cycles = 0
        let runtime = BrowserSyncRuntime(destination: root.appendingPathComponent("sync.json"), interval: .milliseconds(10)) {
            cycles += 1
        }
        #expect(!runtime.hasScheduledCycle)
        try await Task.sleep(for: .milliseconds(35))
        #expect(cycles == 0)
        // Positive checks poll: a loaded host can delay the 10 ms cycles.
        func waitForCycle(after count: Int) async throws {
            // Generous bound for a loaded machine; the loop ends as soon as the cycle runs.
            let deadline = ContinuousClock.now + .seconds(30)
            while cycles <= count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }
        for _ in 0..<2 {
            let before = cycles
            try await runtime.setEnabled(true)
            try await waitForCycle(after: before)
            #expect(cycles > before)
            try await runtime.setEnabled(false)
            let stopped = cycles
            try await Task.sleep(for: .milliseconds(35))
            #expect(cycles == stopped)
            #expect(!runtime.hasScheduledCycle)
        }
        try await runtime.setEnabled(true)
        await runtime.prepareForTermination()
        #expect(!runtime.hasScheduledCycle)
        let stopped = cycles
        runtime.resumeAfterCancelledTermination()
        try await waitForCycle(after: stopped)
        #expect(cycles > stopped)
        await runtime.prepareForTermination()
    }

    @Test("Account change pauses without self-await; sign-out keeps retrying")
    func accountLifecycle() async throws {
        for error in [BrowserSyncError.accountChanged, .signedOut] {
            let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var cycles = 0
            let runtime = BrowserSyncRuntime(destination: root.appendingPathComponent("sync.json"), interval: .milliseconds(10)) {
                cycles += 1
                throw error
            }
            try await runtime.setEnabled(true)
            // Poll instead of a fixed sleep: a loaded host can delay the 10 ms cycles.
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if error == .accountChanged ? !runtime.hasScheduledCycle : cycles > 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            if error == .accountChanged {
                #expect(cycles == 1)
                #expect(!runtime.enabled && !runtime.hasScheduledCycle && runtime.needsAccountDecision)
            } else {
                #expect(cycles > 1)
                #expect(runtime.enabled)
            }
            await runtime.prepareForTermination()
        }
    }

    private func root() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
    }
    private func wait(until condition: () -> Bool) async throws {
        // Generous bound for a loaded machine; the loop ends as soon as the condition holds.
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Idle sync runs no cycle between safety ticks; the launch cycle is immediate")
    func idleRuntimeDoesNotPoll() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var cycles = 0
        let runtime = BrowserSyncRuntime(destination: root.appendingPathComponent("sync.json"), interval: .milliseconds(10),
                                         debounce: .milliseconds(20), safetyInterval: .seconds(60)) { cycles += 1 }
        try await runtime.setEnabled(true)
        try await wait { cycles == 1 }
        #expect(cycles == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(cycles == 1)
        #expect(runtime.hasScheduledCycle)
        await runtime.prepareForTermination()
    }

    @Test("A burst of local changes triggers one debounced cycle; a remote push triggers another")
    func localAndRemoteWakes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var cycles = 0
        let runtime = BrowserSyncRuntime(destination: root.appendingPathComponent("sync.json"), interval: .milliseconds(10),
                                         debounce: .milliseconds(150), safetyInterval: .seconds(60)) { cycles += 1 }
        try await runtime.setEnabled(true)
        try await wait { cycles == 1 }
        // Counts are relative and the burst is synchronous, so a loaded host cannot split it.
        var before = cycles
        for _ in 0..<5 { runtime.localStateChanged() }
        #expect(cycles == before)
        try await wait { cycles > before }
        try await Task.sleep(for: .milliseconds(300))
        #expect(cycles == before + 1)
        before = cycles
        runtime.remoteChangeArrived()
        try await wait { cycles > before }
        try await Task.sleep(for: .milliseconds(300))
        #expect(cycles == before + 1)
        // Account changes also wake (with a forced refresh).
        before = cycles
        runtime.accountChanged()
        try await wait { cycles > before }
        #expect(cycles == before + 1)
        await runtime.prepareForTermination()
    }

    @Test("Committed store edits and account notifications reach an observing runtime")
    func notificationPlumbing() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var cycles = 0
        let runtime = BrowserSyncRuntime(destination: root.appendingPathComponent("sync.json"), interval: .milliseconds(10),
                                         debounce: .milliseconds(20), safetyInterval: .seconds(60), observesSignals: true) { cycles += 1 }
        try await runtime.setEnabled(true)
        try await wait { cycles >= 1 }
        let settings = try BrowserSettingsStore(destination: root.appendingPathComponent("settings.json"))
        let before = cycles
        try await settings.setReducedMotion(.reduce)
        try await wait { cycles > before }
        #expect(cycles > before)
        let afterSettings = cycles
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        try await wait { cycles > afterSettings }
        #expect(cycles > afterSettings)
        await runtime.prepareForTermination()
    }

    @Test("The safety timer still cycles when nothing signals; a local race retries without a signal")
    func safetyTimerAndLocalRace() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        var cycles = 0
        var raced = true
        let runtime = BrowserSyncRuntime(destination: root.appendingPathComponent("sync.json"), interval: .milliseconds(10),
                                         debounce: .milliseconds(10), safetyInterval: .milliseconds(150)) {
            cycles += 1
            if raced { raced = false; throw BrowserSyncError.localChange }
        }
        try await runtime.setEnabled(true)
        try await wait { cycles >= 2 }
        #expect(cycles >= 2)
        let settled = cycles
        try await wait { cycles > settled }
        #expect(cycles > settled)
        await runtime.prepareForTermination()
    }

    @Test("Turning sync off deletes this Mac's sync caches and keeps the sync state")
    func disableRemovesLocalCaches() async throws {
        let root = root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("sync.json")
        let runtime = BrowserSyncRuntime(destination: destination, interval: .milliseconds(10)) {}
        try await runtime.setEnabled(true)
        let caches = ["cloudkit", "cloudkit.sealed-v1", "history.cloudkit", "history.cloudkit.engine",
                      "history.cloudkit.sqlite", "passwords.sealed", "passwords.cloudkit.sealed"]
        for name in caches { try Data("synthetic".utf8).write(to: destination.appendingPathExtension(name)) }
        let unrelated = root.appendingPathComponent("session.json")
        try Data("synthetic".utf8).write(to: unrelated)
        try await runtime.setEnabled(false)
        for name in caches { #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension(name).path), "\(name)") }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        // The on/off choice survives in the kept state file.
        #expect(try BrowserSyncState.load(destination).enabled == false)
        await runtime.prepareForTermination()
    }

    @Test("Password sync is off by default; turning it off removes only password caches")
    func passwordToggle() async throws {
        let root = root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("sync.json")
        let runtime = BrowserSyncRuntime(destination: destination, interval: .milliseconds(10)) {}
        #expect(!runtime.passwordsEnabled)
        try await runtime.setEnabled(true)
        #expect(!runtime.passwordsEnabled)
        try await runtime.setPasswordsEnabled(true)
        #expect(runtime.passwordsEnabled)
        #expect(try BrowserSyncState.load(destination).syncsPasswords)
        for name in ["cloudkit", "passwords.sealed", "passwords.cloudkit.sealed"] {
            try Data("synthetic".utf8).write(to: destination.appendingPathExtension(name))
        }
        try await runtime.setPasswordsEnabled(false)
        #expect(!runtime.passwordsEnabled && runtime.enabled)
        #expect(try !BrowserSyncState.load(destination).syncsPasswords)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("passwords.sealed").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("passwords.cloudkit.sealed").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathExtension("cloudkit").path))
        await runtime.prepareForTermination()
    }
}
