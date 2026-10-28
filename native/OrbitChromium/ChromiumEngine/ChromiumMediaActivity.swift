import Foundation

/// CEF 156 has no public acoustic audibility callback. CDP reports native player/graph
/// activity instead. Keep this distinct from audibility, and protect unknown audio tracks.
struct ChromiumMediaActivity {
    struct Player {
        var playing = false
        var hasAudio: Bool?
    }
    var players: [String: Player] = [:]
    var contexts: [String: String] = [:]
    var mediaReady = false
    var webAudioReady = false

    var isPlaying: Bool { players.values.contains { $0.playing } || contexts.values.contains("running") }
    var audioPlaying: Bool? {
        if contexts.values.contains("running") || players.values.contains(where: { $0.playing && $0.hasAudio == true }) { return true }
        if !mediaReady || !webAudioReady || players.values.contains(where: { $0.playing && $0.hasAudio == nil }) { return nil }
        return false
    }

    mutating func receive(method: String, payload: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        if method == "Media.playerEventsAdded", let id = value["playerId"] as? String,
           let events = value["events"] as? [[String: Any]] {
            for item in events {
                guard let text = item["value"] as? String, let data = text.data(using: .utf8),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = record["event"] as? String else { continue }
                if name == "kPlay" { players[id, default: Player()].playing = true }
                else if ["kPause", "kEnded", "kSuspended"].contains(name) { players[id, default: Player()].playing = false }
                else if name == "kWebMediaPlayerDestroyed" { players[id] = nil }
            }
        } else if method == "Media.playerPropertiesChanged", let id = value["playerId"] as? String,
                  let properties = value["properties"] as? [[String: Any]] {
            for item in properties where item["name"] as? String == "kAudioTracks" {
                guard let text = item["value"] as? String, let data = text.data(using: .utf8),
                      let tracks = try? JSONSerialization.jsonObject(with: data) as? [Any] else { continue }
                players[id, default: Player()].hasAudio = !tracks.isEmpty
            }
        } else if method == "WebAudio.contextWillBeDestroyed", let id = value["contextId"] as? String {
            contexts[id] = nil
        } else if let context = value["context"] as? [String: Any],
                  context["contextType"] as? String != "offline",
                  let id = context["contextId"] as? String, let state = context["contextState"] as? String {
            contexts[id] = state
        }
    }
}
