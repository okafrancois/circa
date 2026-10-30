import BrowserEngine
import Foundation
import Testing

@MainActor
private final class MockPagePerformance: BrowserPagePerformance {
    var state: BrowserPageLifecycle?
    var activationStatus: BrowserActivationFrame.Status = .submitted
    var requests: [BrowserNativeCaptureRequest] = []
    var listeners: [AsyncStream<BrowserPageLifecycleChange>.Continuation] = []
    func lifecycle() -> BrowserPageLifecycle? { state }
    func changes() -> AsyncStream<BrowserPageLifecycleChange> { AsyncStream { listeners.append($0) } }
    func publish(_ event: BrowserPageLifecycleChange) { listeners.forEach { $0.yield(event) } }
    func capture(_ request: BrowserNativeCaptureRequest) async -> BrowserNativeCapture {
        requests.append(request)
        return .init(status: .captured, width: request.outputWidth, height: request.outputHeight,
                     rowBytes: UInt32(request.outputWidth) * 4,
                     pixels: Data(repeating: 255, count: Int(request.outputWidth * request.outputHeight) * 4))
    }
    func activationFrame(activationID: UInt64) async -> BrowserActivationFrame {
        .init(browserID: 7, activationID: activationID, documentID: state?.documentID ?? 0,
              status: activationStatus, submittedTicksUS: activationStatus == .submitted ? 123456 : 0)
    }
}

@Suite("Native page performance contract")
@MainActor
struct PagePerformanceContractTests {
    @Test("Missing state stays unknown and native discard provenance reaches consumers in order")
    func discard() async {
        let mock = MockPagePerformance()
        let engine: any BrowserPagePerformance = mock
        #expect(engine.lifecycle() == nil)
        #expect(await engine.memoryDump().status == .unavailable)
        let stream = engine.changes(); var iterator = stream.makeAsyncIterator()
        var state = BrowserPageLifecycle(); state.documentID = 19
        state.hadUserEdits = true; state.cannotDiscardMask = 1 << 27
        mock.state = state
        mock.publish(.init(event: .aboutToDiscard, initiator: .nativePolicy, state: state))
        state.state = .discarded
        mock.publish(.init(event: .discarded, initiator: .nativePolicy, state: state))
        #expect(await iterator.next()?.event == .aboutToDiscard)
        let discarded = await iterator.next()
        #expect(discarded?.initiator == .nativePolicy)
        #expect(discarded?.state?.state == .discarded)
        #expect(discarded?.state?.hadUserEdits == true)
    }
    @Test("Thumbnail and tint consumers request bounded pixels and retain owned bytes")
    func capture() async {
        let mock = MockPagePerformance()
        let thumbnail = await mock.capture(.init(outputWidth: 200, outputHeight: 120))
        #expect(thumbnail.pixels.count == 96000)
        var tint = BrowserNativeCaptureRequest(outputWidth: 64, outputHeight: 1)
        tint.width = 800; tint.height = 2
        let strip = await mock.capture(tint)
        #expect(strip.pixels.count == 256)
        #expect(thumbnail.pixels.count == 96000)
        #expect(mock.requests.last?.height == 2)
    }
    @Test("Activation results preserve native document and activation identities for every outcome")
    func activation() async {
        let mock = MockPagePerformance()
        var state = BrowserPageLifecycle(); state.documentID = 19; mock.state = state
        for status in [BrowserActivationFrame.Status.submitted, .documentChanged, .hidden, .closed, .timedOut] {
            mock.activationStatus = status
            let result = await mock.activationFrame(activationID: 42)
            #expect(result.activationID == 42 && result.documentID == 19 && result.browserID == 7)
            #expect(result.status == status)
            #expect((result.submittedTicksUS > 0) == (status == .submitted))
        }
    }
}
