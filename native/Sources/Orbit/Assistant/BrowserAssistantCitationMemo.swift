import BrowserCore
import Foundation

/// Citation parsing results per message, reused while the message's text, state and sources are
/// unchanged. A streaming token re-evaluates every transcript row in SwiftUI; with this memo only
/// the row whose text changed parses its markers again. Each transcript view owns one memo, so
/// answer text is released with the view.
@MainActor
final class BrowserAssistantCitationMemo {
    struct Entry {
        let hasText: Bool
        let citations: [BrowserAICitation]
        let displayText: String
    }

    private struct Stored {
        let text: String
        let state: BrowserAIMessage.State
        let context: [BrowserAIContextSnapshot]
        let entry: Entry
    }

    let capacity: Int
    private var stored: [UUID: Stored] = [:]
    private(set) var parses = 0

    init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    func entry(_ message: BrowserAIMessage) -> Entry {
        if let hit = stored[message.id], hit.state == message.state, hit.text == message.text, hit.context == message.context {
            return hit.entry
        }
        parses += 1
        // Same results as calling `segments`, `parse` and `displayText` on the message directly.
        var numbers: Set<Int> = []
        let segments = BrowserAICitation.segments(message)
        let entry = Entry(hasText: !segments.isEmpty,
                          citations: BrowserAICitation.parse(message).filter { numbers.insert($0.number).inserted },
                          displayText: BrowserAICitation.displayText(segments))
        if stored[message.id] == nil, stored.count >= capacity { stored.removeAll(keepingCapacity: true) }
        stored[message.id] = Stored(text: message.text, state: message.state, context: message.context, entry: entry)
        return entry
    }
}
