import Foundation
import Testing
@testable import BrowserShell

@Suite("Session save burst coalescing")
struct BrowserSessionSaveBurstTests {
    /// Replays change times against the schedule the way the environment does: a save starts at the
    /// pending deadline unless a newer change arrives first, which only reschedules.
    private func replay(_ changes: [Double], recordsSaves: Bool, metadataOnly: Bool = false) -> [Double] {
        var schedule = BrowserSessionSaveSchedule()
        var saves: [Double] = []
        for time in changes {
            if let deadline = schedule.deadline, deadline <= time {
                saves.append(deadline)
                if recordsSaves { schedule.reset(savedAt: deadline) } else { schedule.reset() }
            }
            schedule.schedule(at: time, metadataOnly: metadataOnly)
        }
        if let deadline = schedule.deadline { saves.append(deadline) }
        return saves
    }

    @Test("A sustained burst saves about once per second instead of every 150 ms")
    func burstIsBounded() {
        let burst = stride(from: 0.0, to: 10, by: 0.016).map { $0 }
        let before = replay(burst, recordsSaves: false)
        let after = replay(burst, recordsSaves: true)
        #expect(after.count <= 11)
        #expect(before.count >= 60)
        // No change waits longer than one second for its save.
        var cursor = 0
        for time in burst {
            while after[cursor] < time { cursor += 1 }
            #expect(after[cursor] - time <= 1.0001)
        }
        print(String(format: "PERF-SHELL-B session saves in a 10 s burst (change every 16 ms) before=%d (%.1f/s) after=%d (%.1f/s)",
                     before.count, Double(before.count) / 10, after.count, Double(after.count) / 10))
    }

    @Test("The first structural change after a quiet second still saves after 150 ms")
    func quietStructuralLatency() {
        var schedule = BrowserSessionSaveSchedule()
        #expect(abs(schedule.schedule(at: 0, metadataOnly: false) - 0.15) < 0.0001)
        schedule.reset(savedAt: 0.15)
        #expect(abs(schedule.schedule(at: 0.5, metadataOnly: false) - 0.65) < 0.0001)   // inside the burst window
        schedule.reset(savedAt: 1.15)
        #expect(abs(schedule.schedule(at: 3, metadataOnly: false) - 0.15) < 0.0001)     // quiet again
        schedule.reset(savedAt: 3.15)
        #expect(abs(schedule.schedule(at: 3.2, metadataOnly: true) - 2.5) < 0.0001)     // metadata keeps its delay
        #expect(schedule.schedule(at: 3.3, metadataOnly: false) <= 0.851)               // and cannot delay structure
        schedule.reset()
        #expect(schedule.lastSave == 3.15)                                              // a plain reset records no save
    }
}
