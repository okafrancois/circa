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
        recorder.mark(.main)
        let first = recorder.phases["main"]
        recorder.mark(.main)
        #expect(recorder.phases["main"] == first)
        recorder.resetCounters()
        #expect(recorder.counters["organizationRefreshes"] == 0)
        #expect(recorder.counters["windowsRefreshed"] == 0)
        #expect(recorder.phases["main"] == first)
    }
}
