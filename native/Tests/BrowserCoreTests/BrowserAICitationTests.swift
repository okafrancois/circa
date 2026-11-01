import Foundation
import Testing
@testable import BrowserCore

struct BrowserAICitationTests {
    @Test func citationsRequireActualSnapshotAndExactPassage() {
        let source = BrowserAIContextSource(id: UUID(), revision: 5, url: URL(string: "https://example.com")!, title: "Example")
        let message = BrowserAIMessage(id: UUID(), role: .assistant, choice: .init(provider: .codex),
            text: #"Answer [1: "An exact passage here"] [2: "An invented passage"] [1: "Another invented passage"]"#,
            state: .completed, context: [.init(source: source, text: "An exact passage here in the document.")])
        let citations = BrowserAICitation.parse(message)
        #expect(citations.count == 1)
        #expect(citations.first?.snapshot.source.revision == 5)
        #expect(citations.first?.passage == "An exact passage here")
    }
    @Test func exactPassageMaySpanExtractedTextNodes() {
        let source = BrowserAIContextSource(id: UUID(), revision: 5, url: URL(string: "https://example.com")!, title: "Example")
        let passage = "An inline\nmarked passage\ncontinues here"
        let message = BrowserAIMessage(id: UUID(), role: .assistant, choice: .init(provider: .codex),
            text: "Answer [1: \"\(passage)\"]", state: .completed,
            context: [.init(source: source, text: passage)])
        #expect(BrowserAICitation.parse(message).first?.passage == passage)
    }

}
