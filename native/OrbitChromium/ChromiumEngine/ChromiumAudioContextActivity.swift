import Foundation

/// The native lifecycle reports playback, but omits running contexts without a source.
/// Observe only context state until the engine can report that distinction itself.
struct ChromiumAudioContextActivity {
    private var contexts: [String: String] = [:]
    private var malformed = false
    var ready = false
    var isRunning: Bool { contexts.values.contains("running") }
    var isKnown: Bool { ready && !malformed }
    var isSafe: Bool { isKnown && !isRunning }

    mutating func receive(method: String, payload: Data) {
        guard method == "WebAudio.contextCreated" || method == "WebAudio.contextChanged"
                || method == "WebAudio.contextWillBeDestroyed" else { return }
        guard let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            malformed = true; return
        }
        if method == "WebAudio.contextWillBeDestroyed" {
            guard let id = value["contextId"] as? String else { malformed = true; return }
            contexts[id] = nil
        } else if method == "WebAudio.contextCreated" || method == "WebAudio.contextChanged" {
            guard let context = value["context"] as? [String: Any],
                  let type = context["contextType"] as? String else { malformed = true; return }
            if type == "offline" { return }
            guard type == "realtime", let id = context["contextId"] as? String,
                  let state = context["contextState"] as? String,
                  ["running", "suspended", "closed", "interrupted"].contains(state) else { malformed = true; return }
            contexts[id] = state
        }
    }
}
