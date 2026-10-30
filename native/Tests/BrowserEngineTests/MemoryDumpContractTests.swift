import BrowserEngine
import Foundation
import Testing

@Suite("Native memory diagnostics")
struct MemoryDumpContractTests {
    private let payload = Data(#"{"outcome":0,"processes":[{"pid":42,"processType":1,"privateFootprintKB":9000,"allocators":{"partition_alloc":{"metrics":{"size":8192},"children":{"partitions":{"metrics":{},"children":{"buffer":{"metrics":{"size":0},"children":{}}}}}}}},{"pid":43,"processType":2,"allocators":{}}]}"#.utf8)

    @Test("Native allocator hierarchy preserves absent versus measured zero and process identity")
    func attribution() {
        let dump = BrowserMemoryDump.decode(payload, status: 1)
        #expect(dump.status == .complete && dump.outcome == 0)
        #expect(dump.processes.map(\.pid) == [42, 43])
        #expect(dump.processes[0].kind == .browser)
        #expect(dump.processes[1].kind == .renderer)
        #expect(dump.processes[1].privateFootprintKB == nil)
        let partition = dump.processes[0].allocators["partition_alloc"]
        #expect(partition?.metrics["size"] == 8192)
        #expect(partition?.children["partitions"]?.children["buffer"]?.metrics["size"] == 0)
        #expect(dump.processes[0].allocators["malloc"] == nil)
    }
    @Test("Partial results retain native failure and malformed or refused results stay unavailable")
    func failure() {
        let partial = Data(String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "\"outcome\":0", with: "\"outcome\":7").utf8)
        #expect(BrowserMemoryDump.decode(partial, status: 2).status == .partial)
        #expect(BrowserMemoryDump.decode(partial, status: 2).outcome == 7)
        for (bytes, status) in [(partial, Int32(1)), (payload, -1), (payload, 0), (Data(), 1)] {
            #expect(BrowserMemoryDump.decode(bytes, status: status).status == .unavailable)
        }
    }
    @Test("Engine focus fix allows the default non-key-window behavior without a feature override")
    func focusConfiguration() throws {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try String(contentsOf: native.appendingPathComponent("OrbitChromium/Bridge/OrbitChromiumBridge.mm"), encoding: .utf8)
        #expect(!bridge.contains("RWHVMacHasFocusReturnsFalseForNonKeyWindow"))
        #expect(bridge.contains("{12u, offsetof(orbit_cef_api_t, memory_dump)}"))
        #expect(bridge.contains("{13u, sizeof(orbit_cef_api_t)}"))
    }
}
