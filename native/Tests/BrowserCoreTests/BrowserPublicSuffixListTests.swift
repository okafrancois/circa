import BrowserCore
import Foundation
import Testing

@Suite("Public Suffix List")
struct BrowserPublicSuffixListTests {
    private let list = BrowserPublicSuffixList.shared

    @Test("The embedded list passes the official ASCII test vectors")
    func officialVectors() {
        #expect(BrowserPublicSuffixVectors.cases.count > 50)
        for (domain, expected) in BrowserPublicSuffixVectors.cases {
            #expect(list.registrableDomain(of: domain) == expected, "\(domain)")
        }
    }

    @Test("Private suffixes, multi-label suffixes, wildcards and exceptions")
    func rules() {
        #expect(list.registrableDomain(of: "alice.github.io") == "alice.github.io")
        #expect(list.registrableDomain(of: "bob.github.io") == "bob.github.io")
        #expect(list.registrableDomain(of: "docs.alice.github.io") == "alice.github.io")
        #expect(list.registrableDomain(of: "github.io") == nil)
        #expect(list.registrableDomain(of: "news.bbc.co.uk") == "bbc.co.uk")
        #expect(list.registrableDomain(of: "x.co.uk") == "x.co.uk")
        #expect(list.registrableDomain(of: "co.uk") == nil)
        // *.ck with the exception !www.ck
        #expect(list.registrableDomain(of: "test.ck") == nil)
        #expect(list.registrableDomain(of: "b.test.ck") == "b.test.ck")
        #expect(list.registrableDomain(of: "www.ck") == "www.ck")
        #expect(list.registrableDomain(of: "www.www.ck") == "www.ck")
        #expect(list.registrableDomain(of: "Mail.Example.COM.") == "example.com")
        #expect(list.registrableDomain(of: "xn--85x722f.xn--55qx5d.cn") == "xn--85x722f.xn--55qx5d.cn")
        #expect(list.registrableDomain(of: "127.0.0.1") == nil)
        #expect(list.registrableDomain(of: "a..example.com") == nil)
    }

    @Test("Sites compare registrable domains, or whole hosts without one")
    func sites() {
        func site(_ string: String) -> String? { list.site(of: URL(string: string)!) }
        #expect(site("https://alice.github.io/x") != site("https://bob.github.io/x"))
        #expect(site("https://a.b.example.com/") == "example.com")
        #expect(site("http://127.0.0.1:8080/") == "127.0.0.1")
        #expect(site("http://localhost:8080/") == "localhost")
        #expect(site("https://github.io/") == "github.io")
    }

    @Test("A custom rule set follows the same algorithm")
    func customRules() {
        let custom = BrowserPublicSuffixList(rules: "com\njp\n*.kawasaki.jp\n!city.kawasaki.jp\n// comment")
        #expect(custom.registrableDomain(of: "a.b.kawasaki.jp") == "a.b.kawasaki.jp")
        #expect(custom.registrableDomain(of: "city.kawasaki.jp") == "city.kawasaki.jp")
        #expect(custom.registrableDomain(of: "shop.example.com") == "example.com")
    }
}
