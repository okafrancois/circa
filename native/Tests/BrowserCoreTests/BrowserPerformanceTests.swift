import Foundation
import Testing
@testable import BrowserCore

@Suite struct BrowserPerformanceTests {
    @Test func requiresBothSyntheticAdmissionAndExplicitProbe() {
        #expect(!BrowserPerformance.isEnabled(synthetic: false, arguments: ["--perf-probe"]))
        #expect(!BrowserPerformance.isEnabled(synthetic: true, arguments: []))
        #expect(BrowserPerformance.isEnabled(synthetic: true, arguments: ["--perf-probe"]))
    }
    @Test func countsAcrossThreadsAndResetsDistinctWindows() async {
        let recorder = BrowserPerformance.Recorder(), window = UUID()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { for _ in 0..<100 { recorder.count(.organizationRefreshes, window: window) } } }
        }
        #expect(recorder.counters["organizationRefreshes"] == 800)
        #expect(recorder.counters["windowsRefreshed"] == 1)
        recorder.count(.resourceSweepNanoseconds, amount: 500)
        recorder.count(.resourceSweepNanoseconds, amount: 300)
        recorder.set(.resourceTabs, 62)
        recorder.set(.resourceTabs, 61)
        #expect(recorder.counters["resourceSweepNanoseconds"] == 800)
        #expect(recorder.counters["resourceTabs"] == 61)
        recorder.mark(.main)
        let first = recorder.phases["main"]
        recorder.mark(.main)
        #expect(recorder.phases["main"] == first)
        recorder.resetCounters()
        #expect(recorder.counters["organizationRefreshes"] == 0)
        #expect(recorder.counters["windowsRefreshed"] == 0)
        #expect(recorder.phases["main"] == first)
    }
    @Test func boundedWorkIntervalsResetIndependentlyOfStartup() {
        let recorder = BrowserPerformance.Recorder()
        recorder.mark(.main)
        for _ in 0..<20001 { recorder.record(.storeCapture, start: 10, end: 10.125) }
        #expect(recorder.work.count == 20000)
        #expect(recorder.work.first?["work"] as? String == "storeCapture")
        #expect(recorder.work.first?["start"] as? Double == 10)
        #expect(recorder.work.first?["end"] as? Double == 10.125)
        recorder.resetWork()
        #expect(recorder.work.isEmpty)
        #expect(recorder.phases["main"] != nil)
    }

}
