import BrowserCore
import Foundation
import Testing

struct SearchBangTests {
    @Test("Only leading and trailing bang tokens match, case insensitively")
    func parsing() throws {
        for input in ["!gh react", "react !gh", "  !GH  react \n", "react\t!Gh"] {
            let bang = try #require(BrowserSearchBang.parse(input))
            #expect(bang.site.name == "GitHub" && bang.query == "react")
        }
        for input in ["", "!", "Hi!", "Hi! react", "react!gh", "hello !gh world", "!unknown react", "react !unknown", "!unknown react !gh"] {
            #expect(BrowserSearchBang.parse(input) == nil)
        }
        let multiple = try #require(BrowserSearchBang.parse("!gh react !g"))
        #expect(multiple.site.name == "GitHub" && multiple.query == "react !g")
        #expect(BrowserSearchBang.parse("!gh !g")?.query == "!g")
        #expect(BrowserSearchBang.parse("!gh two  words")?.query == "two  words")
    }

    @Test("All twenty built-ins use HTTPS, encode queries once and open home when alone")
    func builtIns() throws {
        let hosts = ["g": "www.google.com", "ddg": "duckduckgo.com", "b": "www.bing.com", "gh": "github.com",
                     "w": "fr.wikipedia.org", "yt": "www.youtube.com", "maps": "www.google.com", "gi": "www.google.com",
                     "gn": "news.google.com", "r": "www.reddit.com", "so": "stackoverflow.com", "mdn": "developer.mozilla.org",
                     "npm": "www.npmjs.com", "pypi": "pypi.org", "hn": "hn.algolia.com", "imdb": "www.imdb.com",
                     "wa": "www.wolframalpha.com", "tr": "translate.google.com", "a": "www.amazon.com", "x": "x.com"]
        let query = "two words & # + café 猫 / %"
        let encoded = "two%20words%20%26%20%23%20%2B%20caf%C3%A9%20%E7%8C%AB%20%2F%20%25"
        for (keyword, host) in hosts {
            let bang = try #require(BrowserSearchBang.parse("!\(keyword) \(query)", preferredLanguages: ["fr-FR"]))
            #expect(bang.url.scheme == "https" && bang.url.host == host)
            #expect(bang.url.absoluteString.contains(encoded))
            let home = try #require(BrowserSearchBang.parse("!\(keyword)", preferredLanguages: ["fr-FR"]))
            #expect(home.query.isEmpty && home.url.scheme == "https" && home.url.query == nil)
        }
        #expect(BrowserSearchBang.parse("!gh")?.url.absoluteString == "https://github.com/")
        #expect(BrowserSearchBang.parse("!maps")?.url.absoluteString == "https://www.google.com/maps")
        #expect(BrowserSearchBang.parse("!hn")?.url.host == "news.ycombinator.com")
        #expect(BrowserSearchBang.parse("!w", preferredLanguages: [])?.url.host == "en.wikipedia.org")
        #expect(BrowserSearchBang.parse("!w", preferredLanguages: ["invalid"])?.url.host == "en.wikipedia.org")
    }

    @Test("Configured aliases override built-ins and disabled entries stay inactive")
    func configuredAliases() throws {
        var custom = BrowserSiteSearch(name: "Local", shortcut: "GH", template: "http://127.0.0.1:8123/s?q=%s")
        try custom.validate(in: BrowserSiteSearch.builtIns)
        let entries = BrowserSiteSearch.builtIns + [custom]
        #expect(BrowserSearchBang.parse("!gh hello world", entries: entries)?.url.absoluteString == "http://127.0.0.1:8123/s?q=hello%20world")
        #expect(BrowserSearchBang.parse("!GH", entries: entries)?.url.absoluteString == "http://127.0.0.1:8123/")
        custom.isEnabled = false
        #expect(BrowserSearchBang.parse("!gh react", entries: BrowserSiteSearch.builtIns + [custom]) == nil)
        #expect(BrowserSearchBang.parse("!youtube cats")?.site == BrowserSiteSearch.matching("youtube"))
    }

    @Test("Inline parsing does not change Tab site-search aliases or URL resolution")
    func tabRegression() throws {
        #expect(BrowserSiteSearch.matching("!gh") == nil)
        let site = try #require(BrowserSiteSearch.matching("github.com"))
        #expect(site.url(for: "!gh react")?.absoluteString == "https://github.com/search?q=%21gh%20react")
    }
}
