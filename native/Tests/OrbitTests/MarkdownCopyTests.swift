import Foundation
import Testing
@testable import Orbit

struct MarkdownCopyTests {
    @Test("Markdown link titles escape brackets, pipes and backslashes; destinations escape parentheses")
    func escaping() {
        #expect(BrowserMarkdownLink.format(title: "A [B] | C\\D\nE", url: URL(string: "https://copy.test/a(b)")!)
                == "[A \\[B\\] \\| C\\\\D E](https://copy.test/a%28b%29)")
    }
}
