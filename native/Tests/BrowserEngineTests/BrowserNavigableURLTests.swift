import BrowserEngine
import Foundation
import Testing

@Suite("Shell navigable URLs")
struct BrowserNavigableURLTests {
    @Test("Shell loads accept web, blank, local, data and the product's built-in pages")
    func allowed() throws {
        for text in [
            "https://example.test/path?q=1#top", "http://localhost:8080/", "HTTPS://Example.test/",
            "about:blank", "about:blank#created", "data:text/html,hello", "blob:https://example.test/1234",
            "file:///tmp/synthetic.html", "file://localhost/tmp/synthetic.pdf",
            "view-source:https://example.test/",
            "chrome://settings/", "chrome://settings/languages", "CHROME://Settings/",
            "chrome://password-manager/passwords", "chrome://extensions/", "chrome://extensions/?id=abc",
            "chrome://history/", "chrome://discards",
            "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html",
            "chrome-extension://123e4567-e89b-42d3-a456-426614174000/popup.html",
        ] {
            #expect(BrowserNavigableURL.isShellNavigable(try #require(URL(string: text))), "\(text)")
        }
    }

    @Test("Shell loads refuse script, debug pages and unexposed internal schemes")
    func refused() throws {
        for text in [
            "javascript:alert(1)", "JavaScript:alert(1)", "vbscript:msgbox(1)",
            "chrome://crash", "chrome://crash/", "chrome://kill", "chrome://hang", "chrome://shorthang",
            "chrome://gpucrash", "chrome://gpuhang", "chrome://memory-exhaust", "chrome://inducebrowsercrashforrealz",
            "chrome://quit", "chrome://restart", "chrome://checkcrash", "chrome://%63rash", "chrome://version",
            "chrome://settings:1/", "chrome://user:pass@settings/", "chrome:settings",
            "chrome-untrusted://print/", "devtools://devtools/bundled/inspector.html", "chrome-search://local-ntp/",
            "about:crash", "about:settings", "about:srcdoc", "about:BLANK",
            "file://remote.test/share/doc.html", "file://user@localhost/tmp/a.html",
            "view-source:javascript:alert(1)", "view-source:chrome://crash", "view-source:file:///etc/hosts",
            "chrome-extension://not-an-id/index.html", "filesystem:https://example.test/temporary/a",
            "ftp://example.test/", "mailto:someone@example.test", "ws://example.test/", "https:///nohost",
        ] {
            #expect(!BrowserNavigableURL.isShellNavigable(try #require(URL(string: text))), "\(text)")
        }
    }

    @Test("A refusal is reported to the caller every time")
    func admitsRepeatedly() throws {
        let crash = try #require(URL(string: "chrome://crash"))
        #expect(!BrowserNavigableURL.admits(crash, engine: "test"))
        #expect(!BrowserNavigableURL.admits(crash, engine: "test"))
        #expect(BrowserNavigableURL.admits(try #require(URL(string: "https://example.test/")), engine: "test"))
    }
}
