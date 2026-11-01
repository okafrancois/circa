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

    private func message(_ text: String, page: String, state: BrowserAIMessage.State = .completed) -> BrowserAIMessage {
        let source = BrowserAIContextSource(id: UUID(), revision: 5, url: URL(string: "https://example.com")!, title: "Example")
        return BrowserAIMessage(id: UUID(), role: .assistant, choice: .init(provider: .codex), text: text, state: state,
                                context: [.init(source: source, text: page)])
    }

    @Test func segmentsKeepOnlyValidatedCitations() {
        let page = "An exact passage here in the document."
        let value = message(#"Before [1: "An exact passage here"] middle [2: "Out of range passage"] [1: "An invented passage"] [1: "short"] after"#, page: page)
        let segments = BrowserAICitation.segments(value)
        let citations = segments.compactMap { if case .citation(let citation) = $0 { citation } else { nil } }
        #expect(citations.map(\.passage) == ["An exact passage here"])
        #expect(citations == BrowserAICitation.parse(value))
        let text = segments.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
        #expect(!text.contains("[") && !text.contains("invented") && text.contains("Before") && text.contains("after"))
        #expect(BrowserAICitation.displayText(value).hasPrefix("Before middle"))
    }

    @Test func partialMarkerStaysHiddenWhileStreamingAndAfterStop() {
        for partial in ["[", "[1", "[1:", #"[1: "#, #"[1: "An exact"#, #"[1: "An exact passage here""#] {
            #expect(BrowserAICitation.displayText(message("Answer " + partial, page: "x", state: .streaming)) == "Answer")
        }
        #expect(BrowserAICitation.displayText(message(#"Answer [1: "An exact"#, page: "x", state: .stopped)) == "Answer")
        // Ordinary brackets survive once the answer is final.
        #expect(BrowserAICitation.displayText(message("See [the note] and [2", page: "x")) == "See [the note] and [2")
    }

    @Test func userTextIsNeverParsed() {
        let user = BrowserAIMessage(id: UUID(), role: .user, choice: .init(provider: .codex),
                                    text: #"Quote [1: "An exact passage here"]"#, state: .completed, context: [])
        #expect(BrowserAICitation.segments(user) == [.text(user.text)])
    }
}
