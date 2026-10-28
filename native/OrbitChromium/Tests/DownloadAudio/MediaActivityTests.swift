import Foundation

@main struct MediaActivityTests {
    static func main() {
        var activity = ChromiumMediaActivity()
        func send(_ name: String, _ object: [String: Any]) {
            activity.receive(method: name, payload: try! JSONSerialization.data(withJSONObject: object))
        }
        func event(_ id: String, _ name: String) {
            send("Media.playerEventsAdded", ["playerId": id, "events": [["value": "{\"event\":\"\(name)\"}"]]])
        }
        func audio(_ id: String, _ tracks: String) {
            send("Media.playerPropertiesChanged", ["playerId": id, "properties": [["name": "kAudioTracks", "value": tracks]]])
        }
        precondition(activity.audioPlaying == nil)
        activity.mediaReady = true; activity.webAudioReady = true
        precondition(activity.audioPlaying == false)
        event("audio", "kPlay")
        precondition(activity.isPlaying && activity.audioPlaying == nil)
        audio("audio", "[{\"codec\":\"pcm\"}]")
        precondition(activity.audioPlaying == true)
        event("audio", "kPause")
        precondition(!activity.isPlaying && activity.audioPlaying == false)
        event("video", "kPlay"); audio("video", "[]")
        precondition(activity.isPlaying && activity.audioPlaying == false)
        event("audio", "kPlay"); event("video", "kEnded")
        precondition(activity.audioPlaying == true)
        event("audio", "kWebMediaPlayerDestroyed")
        precondition(activity.audioPlaying == false)
        send("WebAudio.contextCreated", ["context": ["contextId": "offline", "contextType": "offline", "contextState": "running"]])
        precondition(activity.audioPlaying == false)
        send("WebAudio.contextCreated", ["context": ["contextId": "tone", "contextType": "realtime", "contextState": "running"]])
        precondition(activity.audioPlaying == true)
        send("WebAudio.contextChanged", ["context": ["contextId": "tone", "contextState": "suspended"]])
        precondition(activity.audioPlaying == false)
        send("WebAudio.contextWillBeDestroyed", ["contextId": "tone"])
        precondition(activity.contexts.isEmpty)
        event("video", "kWebMediaPlayerDestroyed")
        precondition(activity.players.isEmpty)
        print("PASS native CDP metadata: audio/video, unknown tracks, play/pause/end/destroy, realtime/offline Web Audio")
    }
}
