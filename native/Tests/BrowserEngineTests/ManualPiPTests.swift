import Foundation
import Testing
@testable import BrowserEngine

@MainActor
@Suite struct ManualPiPTests {
    @MainActor final class FakeTransport {
        var eligible = true
        var enters = true
        var generation: UInt64? = 4
        var calls: [(String, [String: Any])] = []
        var exits = 0
        var control: [String: Any]? = ["paused": true, "position": 3.25, "duration": 12, "rate": 1]
        var staleContexts = 0
        func call(_ method: String, _ parameters: String) async -> (Bool, Data) {
            let params = (try? JSONSerialization.jsonObject(with: Data(parameters.utf8)) as? [String: Any]) ?? [:]
            calls.append((method, params))
            let result: [String: Any]
            switch method {
            case "Page.getFrameTree": result = ["frameTree": ["frame": ["id": "main"], "childFrames": [["frame": ["id": "cross-origin"]]]]]
            case "Page.createIsolatedWorld": result = ["executionContextId": 9]
            case "Runtime.evaluate" where (params["expression"] as? String)?.contains("orbitMediaControlTarget") == true:
                if staleContexts > 0 { staleContexts -= 1; return (false, Data()) }
                result = ["result": ["value": control as Any]]
            default: result = ["result": ["value": params["userGesture"] as? Bool == true ? enters : eligible]]
            }
            return (true, try! JSONSerialization.data(withJSONObject: result))
        }
        func adapter() -> BrowserManualPiP {
            BrowserManualPiP(transport: { method, params in await self.call(method, params) }, generation: { self.generation }, exit: { self.exits += 1 })
        }
    }
    @Test func eligibilityAndFailure() async {
        let fake = FakeTransport(), pip: BrowserManualPiP
        pip = fake.adapter()
        await pip.refresh()
        #expect(pip.state == .ready)
        #expect(fake.calls[1].1["frameId"] as? String == "main")
        #expect(fake.calls.count == 3)
        fake.enters = false
        await pip.toggle()
        #expect(pip.state == .failed)
        #expect(fake.calls.last?.1["userGesture"] as? Bool == true)
        #expect(fake.calls.last?.1["awaitPromise"] as? Bool == true)
        #expect(fake.calls.last?.1["contextId"] as? Int == 9)
        fake.generation = 5
        await pip.toggle()
        #expect(pip.state == .unavailable)
        #expect(fake.calls.count == 4)
        fake.eligible = false
        await pip.refresh()
        #expect(pip.state == .unavailable)
    }
    @Test func acknowledgementAndExit() async {
        let fake = FakeTransport(), pip: BrowserManualPiP
        pip = fake.adapter()
        await pip.refresh()
        let task = Task { await pip.toggle() }
        while pip.state != .requesting { await Task.yield() }
        pip.acknowledge(active: true)
        #expect(pip.state == .active)
        await pip.toggle()
        #expect(fake.exits == 1 && pip.state == .active)
        pip.acknowledge(active: false)
        #expect(pip.state == .unavailable)
        task.cancel()
        await task.value
    }
    @Test func missingAcknowledgementFails() async {
        let fake = FakeTransport(), pip: BrowserManualPiP
        pip = fake.adapter()
        await pip.refresh()
        await pip.toggle()
        #expect(pip.state == .failed)
    }
    @Test func mediaElementControlSharesTheIsolatedWorld() async throws {
        let fake = FakeTransport(), pip: BrowserManualPiP
        pip = fake.adapter()
        let state = try #require(await pip.controlMedia(.pause, seconds: 0))
        #expect(state == BrowserMediaElementState(paused: true, position: 3.25, duration: 12, playbackRate: 1))
        #expect(fake.calls.map(\.0) == ["Page.getFrameTree", "Page.createIsolatedWorld", "Runtime.evaluate"])
        let call = fake.calls[2].1
        #expect(call["contextId"] as? Int == 9 && call["userGesture"] as? Bool == true && call["awaitPromise"] as? Bool == true)
        #expect((call["expression"] as? String)?.hasSuffix("('pause', 0.0)") == true)
        // The world is reused for the same document, and recreated once when it stops answering.
        _ = await pip.controlMedia(.seek, seconds: 6.5)
        #expect(fake.calls.count == 4 && (fake.calls[3].1["expression"] as? String)?.hasSuffix("('seek', 6.5)") == true)
        fake.staleContexts = 1
        #expect(await pip.controlMedia(.play, seconds: 0) != nil)
        #expect(fake.calls.count == 8)
        // No element, another document, or an action the element cannot take: nil.
        fake.control = nil
        #expect(await pip.controlMedia(.play, seconds: 0) == nil)
        #expect(await pip.controlMedia(.next, seconds: 0) == nil)
        #expect(await pip.controlMedia(.seek, seconds: .nan) == nil)
        fake.generation = nil
        #expect(await pip.controlMedia(.play, seconds: 0) == nil)
        #expect(BrowserManualPiP.control.contains("currentTime") && BrowserManualPiP.control.contains("pause()"))
    }
    @Test func manualScriptDoesNotClaimAutomaticOwnership() {
        #expect(!BrowserManualPiP.enter.contains("orbitAutomaticPiP"))
        #expect(BrowserManualPiP.enter.contains("requestPictureInPicture"))
        #expect(BrowserManualPiP.query.contains("disablePictureInPicture"))
    }
}
