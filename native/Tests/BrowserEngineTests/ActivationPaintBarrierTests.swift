import AppKit
import BrowserEngine
import Testing

@MainActor
private final class ActivationPerformance: BrowserPagePerformance {
    var state: BrowserPageLifecycle? = {
        var state = BrowserPageLifecycle(); state.documentID = 19; return state
    }()
    var requests: [UInt64] = []
    var reply: CheckedContinuation<BrowserActivationFrame, Never>?
    func lifecycle() -> BrowserPageLifecycle? { state }
    func changes() -> AsyncStream<BrowserPageLifecycleChange> { AsyncStream { $0.finish() } }
    func capture(_ request: BrowserNativeCaptureRequest) async -> BrowserNativeCapture { .init(status: .unavailable) }
    func activationFrame(activationID: UInt64) async -> BrowserActivationFrame {
        requests.append(activationID)
        return await withCheckedContinuation { reply = $0 }
    }
    func complete(status: BrowserActivationFrame.Status = .submitted, browser: Int32 = 7,
                  activation: UInt64 = 42, document: UInt64 = 19, ticks: Int64 = 123) {
        reply?.resume(returning: .init(browserID: browser, activationID: activation,
            documentID: document, status: status, submittedTicksUS: ticks))
        reply = nil
    }
}

@Suite("Activation paint readiness", .serialized)
@MainActor
struct ActivationPaintBarrierTests {
    @Test("Only a matching submitted frame permits early retirement", arguments: [
        "submitted", "documentChanged", "hidden", "closed", "timedOut", "browser", "activation", "document", "ticks"
    ])
    func result(_ kind: String) async {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: .init(x: 0, y: 0, width: 320, height: 240))
        window.contentView = host
        let api = ActivationPerformance()
        let task = Task { await BrowserActivationPaintBarrier.wait(performance: api, host: host,
            browserID: 7, activationID: 42, isCurrent: { true }) }
        while api.reply == nil { await Task.yield() }
        let status: BrowserActivationFrame.Status = switch kind {
        case "documentChanged": .documentChanged
        case "hidden": .hidden
        case "closed": .closed
        case "timedOut": .timedOut
        default: .submitted
        }
        api.complete(status: status, browser: kind == "browser" ? 8 : 7,
            activation: kind == "activation" ? 43 : 42, document: kind == "document" ? 20 : 19,
            ticks: kind == "ticks" ? 0 : 123)
        #expect(await task.value == (kind == "submitted"))
    }

    @Test("Changes while waiting invalidate submission readiness", arguments: [
        "generation", "geometry", "detach", "hidden", "navigation", "discard", "cancel"
    ])
    func stale(_ change: String) async {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: .init(x: 0, y: 0, width: 320, height: 240))
        let host = NSView(frame: root.bounds)
        window.contentView = root; root.addSubview(host)
        let api = ActivationPerformance()
        var current = true
        let task = Task { await BrowserActivationPaintBarrier.wait(performance: api, host: host,
            browserID: 7, activationID: 42, isCurrent: { current }) }
        while api.reply == nil { await Task.yield() }
        switch change {
        case "generation": current = false
        case "geometry": host.setFrameSize(.init(width: 300, height: 240))
        case "detach": host.removeFromSuperview()
        case "hidden": host.isHidden = true
        case "navigation": api.state?.documentID = 20
        case "discard": api.state?.state = .discarded
        default: task.cancel()
        }
        api.complete()
        #expect(await task.value == false)
    }

    @Test("Unattached, empty, unknown or superseded hosts never register", arguments: [
        "unattached", "empty", "unknown", "zeroDocument", "discarded", "superseded", "zeroActivation"
    ])
    func registration(_ condition: String) async {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: .init(x: 0, y: 0, width: 320, height: 240))
        let host = NSView(frame: root.bounds)
        window.contentView = root
        if condition != "unattached" { root.addSubview(host) }
        let api = ActivationPerformance()
        if condition == "empty" { host.setFrameSize(.zero) }
        if condition == "unknown" { api.state = nil }
        if condition == "zeroDocument" { api.state?.documentID = 0 }
        if condition == "discarded" { api.state?.state = .discarded }
        #expect(await BrowserActivationPaintBarrier.wait(performance: api, host: host,
            browserID: 7, activationID: condition == "zeroActivation" ? 0 : 42,
            isCurrent: { condition != "superseded" }) == false)
        #expect(api.requests.isEmpty)
    }
}
