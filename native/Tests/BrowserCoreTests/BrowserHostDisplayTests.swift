@testable import BrowserCore
import Foundation
import Testing

@Suite("IDN host display")
struct BrowserHostDisplayTests {
    private func display(_ text: String) -> String { BrowserHostDisplay.displayHost(URL(string: text)!) }

    @Test("Lookalike and mixed-script hosts stay in ASCII")
    func spoofsStayASCII() {
        #expect(display("https://xn--pple-43d.com/") == "xn--pple-43d.com") // Cyrillic а + Latin
        #expect(display("https://аpple.com/") == "xn--pple-43d.com")
        #expect(display("https://сосо.com/") == URL(string: "https://сосо.com/")!.host) // all-Cyrillic lookalikes
        #expect(display("https://gıthub.com/").hasPrefix("xn--")) // dotless i
        #expect(display("https://οροα.com/").hasPrefix("xn--")) // all-Greek lookalikes
        #expect(display("https://pаypal.com/").hasPrefix("xn--"))
        #expect(display("https://ーabc.jp/").hasPrefix("xn--"))
        #expect(display("https://a一b.jp/").hasPrefix("xn--"))
        #expect(display("https://１２３.com/") == "123.com") // IDNA maps fullwidth digits to ASCII
        #expect(display("https://१२३.com/").hasPrefix("xn--")) // non-ASCII digits
        #expect(display("https://ーー.jp/").hasPrefix("xn--")) // prolonged sound mark without kana
        #expect(BrowserSuggestionText.displayURL(URL(string: "https://xn--pple-43d.com/login")!) == "https://xn--pple-43d.com/login")
    }

    @Test("ASCII and legitimate single-script IDN hosts display decoded")
    func legitimateHosts() {
        #expect(display("https://Example.com/") == "Example.com")
        #expect(display("https://xn--mnchen-3ya.de/") == "münchen.de")
        #expect(display("https://例え.jp/") == "例え.jp")
        #expect(display("https://コーヒー.jp/") == "コーヒー.jp")
        #expect(display("https://яндекс.рф/") == "яндекс.рф")
        #expect(display("https://ελλάδα.gr/") == "ελλάδα.gr")
        #expect(display("https://한국.kr/") == "한국.kr")
        #expect(display("https://www.xn--pple-43d.münchen.de/") == "www.xn--pple-43d.münchen.de") // per label
        #expect(BrowserSuggestionText.displayURL(URL(string: "https://user:pw@münchen.de/caf%C3%A9")!) == "https://münchen.de/café")
    }

    @Test("Matching uses the ASCII host: an ASCII query never matches a diacritic or lookalike host")
    func asciiMatching() {
        let lookalike = URL(string: "https://göögle.com/")!
        let real = URL(string: "https://google.com/")!
        #expect(BrowserHostDisplay.asciiHost(lookalike).hasPrefix("xn--"))
        #expect(!BrowserSuggestionText.searchableURL(lookalike).contains("google"))
        #expect(!BrowserSuggestionText.matches("google", title: "", url: lookalike))
        #expect(!BrowserSuggestionText.matches("apple", title: "", url: URL(string: "https://аpple.com/")!))
        #expect(BrowserSuggestionText.matches("google", title: "", url: real))
        #expect(BrowserSuggestionText.matches("café", title: "", url: URL(string: "https://münchen.de/caf%C3%A9")!))
        #expect(BrowserHostDisplay.asciiHost(URL(string: "https://Example.COM/")!) == "example.com")
    }
}
