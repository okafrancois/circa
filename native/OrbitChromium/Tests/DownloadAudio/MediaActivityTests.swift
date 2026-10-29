import Foundation

@main struct MediaActivityTests {
    static func main() {
        var check = ChromiumAudioContextActivity()
        func context(_ state: String, type: String = "realtime") {
            let data = try! JSONSerialization.data(withJSONObject: ["context": ["contextId": "test", "contextType": type, "contextState": state]])
            check.receive(method: "WebAudio.contextCreated", payload: data)
        }
        precondition(!check.isSafe)
        check.ready = true
        precondition(check.isSafe)
        check.receive(method: "WebAudio.audioNodeCreated", payload: Data("ignored".utf8))
        precondition(check.isSafe)
        context("running", type: "offline"); precondition(check.isSafe)
        context("running"); precondition(!check.isSafe)
        context("suspended"); precondition(check.isSafe)
        context("running"); precondition(!check.isSafe)
        check.receive(method: "WebAudio.contextWillBeDestroyed", payload: Data(#"{"contextId":"test"}"#.utf8))
        precondition(check.isSafe)
        context("unrecognized"); precondition(!check.isSafe)
        check = ChromiumAudioContextActivity(); check.ready = true
        check.receive(method: "WebAudio.contextCreated", payload: Data("{}".utf8))
        precondition(!check.isSafe)
        print("PASS residual audio context observation: running, offline, stopped, destroyed and unknown state")
    }
}
