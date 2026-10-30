import BrowserCore
import Foundation
import Testing
@testable import BrowserShell

@MainActor
private final class FreezeSurface: BrowserSurface {
    var currentURL: URL? { nil }
    var disposed = false
    func dispose() { disposed = true }
}

@Suite(.serialized)
@MainActor
struct WindowFreezeTests {
    @Test("Watchdog identifies a stuck presentation without dropping queued selection")
    func watchdogPreservesIntent() async throws {
        let session = BrowserWindowSession(makeSurface: { _, _ in FreezeSurface() })
        await session.waitForPendingCommands()
        let window = try #require(session.snapshot?.id)
        session.commandWatchdogDelay = .milliseconds(20)
        var reports: [BrowserSessionCommandDiagnostic.Report] = []
        session.onCommandStall = { reports.append($0) }
        var release: CheckedContinuation<Void, Never>?
        session.enqueue(kind: "synthetic-presentation") { owner in
            owner.activeCommandDiagnostic?.step = "synthetic-callback"
            await withCheckedContinuation { release = $0 }
        }
        session.openTab()
        let deadline = ContinuousClock.now + .seconds(1)
        while reports.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reports.contains { $0.kind == "synthetic-presentation" && $0.step == "synthetic-callback" && $0.windowID == window.rawValue.uuidString })
        #expect(reports.contains { $0.kind == "openTab(url:activate:at:)" && $0.step == "previous-command" })
        #expect(session.snapshot?.tabs.isEmpty == true)
        release?.resume()
        await session.waitForPendingCommands()
        #expect(session.snapshot?.tabs.count == 1)
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Synchronous retirement disposes surfaces even with a missing callback")
    func retirementBypassesWait() async throws {
        let session = BrowserWindowSession(makeSurface: { _, _ in FreezeSurface() })
        session.openTab()
        await session.waitForPendingCommands()
        let surface = try #require(session.selectedSurface)
        var release: CheckedContinuation<Void, Never>?
        session.enqueue { _ in await withCheckedContinuation { release = $0 } }
        while release == nil { await Task.yield() }
        session.close()
        #expect(session.isClosed && surface.disposed && session.snapshot == nil)
        release?.resume()
        await session.waitForPendingCommands()
    }

    @Test("Finished commands cancel their diagnostic deadline")
    func noSpuriousStall() async throws {
        let session = BrowserWindowSession(makeSurface: { _, _ in FreezeSurface() })
        await session.waitForPendingCommands()
        session.commandWatchdogDelay = .milliseconds(10)
        var count = 0
        session.onCommandStall = { _ in count += 1 }
        session.openTab()
        await session.waitForPendingCommands()
        try await Task.sleep(for: .milliseconds(30))
        #expect(count == 0)
        session.close()
        await session.waitForPendingCommands()
    }
}
