import Foundation
import Testing
import BrowserCore
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
        for _ in 0..<2 {
            try await runtime.setEnabled(true)
            try await Task.sleep(for: .milliseconds(35))
            #expect(cycles > 0)
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
        try await Task.sleep(for: .milliseconds(35))
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
            try await Task.sleep(for: .milliseconds(50))
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
}
