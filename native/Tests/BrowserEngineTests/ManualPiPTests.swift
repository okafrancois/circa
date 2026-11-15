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
        func call(_ method: String, _ parameters: String) async -> (Bool, Data) {
            let params = (try? JSONSerialization.jsonObject(with: Data(parameters.utf8)) as? [String: Any]) ?? [:]
            calls.append((method, params))
            let result: [String: Any]
            switch method {
            case "Page.getFrameTree": result = ["frameTree": ["frame": ["id": "main"], "childFrames": [["frame": ["id": "cross-origin"]]]]]
            case "Page.createIsolatedWorld": result = ["executionContextId": 9]
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
    @Test func manualScriptDoesNotClaimAutomaticOwnership() {
        #expect(!BrowserManualPiP.enter.contains("orbitAutomaticPiP"))
        #expect(BrowserManualPiP.enter.contains("requestPictureInPicture"))
        #expect(BrowserManualPiP.query.contains("disablePictureInPicture"))
    }
}
