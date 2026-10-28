import BrowserEngine
import Foundation
import Testing
@testable import Orbit

@Suite("Peek routing rule")
struct PeekRoutingTests {
    private func request(
        _ kind: BrowserPeekRequestKind = .newTarget, role: BrowserPeekSourceRole = .pinned,
        from source: String = "https://app.example.com/inbox", home: String? = nil,
        to destination: String = "https://news.other.org/story", modifiers: BrowserModifierKeys = [],
        button: Int = 0, mainFrame: Bool? = nil, userLink: Bool = true, replayable: Bool = true
    ) -> BrowserPeekLinkRequest {
        BrowserPeekLinkRequest(kind: kind, sourceRole: role, sourceURL: URL(string: source),
                               sourceHomeURL: home.flatMap(URL.init(string:)), destinationURL: URL(string: destination),
                               modifiers: modifiers, buttonNumber: button, isMainFrame: mainFrame,
                               isUserLinkActivation: userLink, isReplayableRequest: replayable)
    }

    private let defaults = BrowserPeekSettings()

    @Test("Shift-click opens Peek from any tab, including same-site links, unless turned off")
    func shiftClick() {
        for role in [BrowserPeekSourceRole.unpinned, .unclassified, .pinned, .favorite] {
            #expect(BrowserPeekRouting.decide(request(role: role, modifiers: [.shift]), settings: defaults) == .peek(.shiftClick))
        }
        #expect(BrowserPeekRouting.decide(request(role: .unpinned, to: "https://app.example.com/other", modifiers: [.shift]),
                                          settings: defaults) == .peek(.shiftClick))
        #expect(BrowserPeekRouting.decide(request(.navigation, role: .unpinned, modifiers: [.shift], mainFrame: true),
                                          settings: defaults) == .peek(.shiftClick))
        var off = defaults
        off.shiftClickOpensPeek = false
        #expect(BrowserPeekRouting.decide(request(role: .unpinned, modifiers: [.shift]), settings: off) == .decline)
    }

    @Test("Other modifiers and buttons keep their meaning: background tab, Little Orbit, foreground tab")
    func otherModifiers() {
        for modifiers: BrowserModifierKeys in [[.command], [.command, .option], [.command, .shift], [.control], [.option], [.shift, .option]] {
            #expect(BrowserPeekRouting.decide(request(modifiers: modifiers), settings: defaults) == .decline, "\(modifiers)")
        }
        #expect(BrowserPeekRouting.decide(request(button: 2), settings: defaults) == .decline)
        #expect(BrowserPeekRouting.decide(request(modifiers: [.shift], button: 2), settings: defaults) == .decline)
    }

    @Test("Links leaving the site of a Pinned tab or Favorite open in Peek; same-site links stay")
    func pinnedSources() {
        #expect(BrowserPeekRouting.decide(request(role: .pinned), settings: defaults) == .peek(.pinnedSourceLeavingSite))
        #expect(BrowserPeekRouting.decide(request(role: .favorite), settings: defaults) == .peek(.pinnedSourceLeavingSite))
        #expect(BrowserPeekRouting.decide(request(to: "https://docs.example.com/a"), settings: defaults) == .decline)
        #expect(BrowserPeekRouting.decide(request(to: "https://example.com/a"), settings: defaults) == .decline)
        #expect(BrowserPeekRouting.decide(request(role: .unpinned), settings: defaults) == .decline)
        #expect(BrowserPeekRouting.decide(request(role: .unclassified), settings: defaults) == .decline)
        var off = defaults
        off.opensPinnedLinksInPeek = false
        #expect(BrowserPeekRouting.decide(request(role: .pinned), settings: off) == .decline)
        // A pinned tab that already left its home site behaves like a normal tab.
        #expect(BrowserPeekRouting.decide(request(home: "https://mail.home.net/"), settings: defaults) == .decline)
        #expect(BrowserPeekRouting.decide(request(home: "https://www.example.com/"), settings: defaults) == .peek(.pinnedSourceLeavingSite))
    }

    @Test("Only user link activations open Peek; a navigation must also be a replayable GET")
    func userLinkActivationAndReplayableRequests() {
        // Unknown or scripted: a popup opened by script, a form, a redirect, a history move.
        for modifiers: BrowserModifierKeys in [[], [.shift]] {
            #expect(BrowserPeekRouting.decide(request(modifiers: modifiers, userLink: false), settings: defaults) == .decline)
            #expect(BrowserPeekRouting.decide(request(.navigation, modifiers: modifiers, mainFrame: true, userLink: false),
                                              settings: defaults) == .decline)
            // A POST or a request with a body cannot be cancelled in the tab and loaded again.
            #expect(BrowserPeekRouting.decide(request(.navigation, modifiers: modifiers, mainFrame: true, replayable: false),
                                              settings: defaults) == .decline)
        }
        // A new target keeps its original request: method and body do not matter.
        #expect(BrowserPeekRouting.decide(request(modifiers: [.shift], replayable: false), settings: defaults) == .peek(.shiftClick))
        #expect(BrowserPeekRouting.decide(request(.navigation, mainFrame: true), settings: defaults) == .peek(.pinnedSourceLeavingSite))
        #expect(BrowserPeekRouting.decide(request(.navigation, modifiers: [.shift], mainFrame: true), settings: defaults) == .peek(.shiftClick))
        #expect(BrowserPeekRouting.decide(request(.navigation, modifiers: [.shift], mainFrame: false), settings: defaults) == .decline)
    }

    @Test("Meeting links, sign-in flows, credentials and non-web schemes never open Peek")
    func exclusions() {
        for destination in ["https://meet.google.com/abc-defg-hij", "https://us02web.zoom.us/j/123", "https://teams.microsoft.com/l/meetup-join/x",
                            "https://accounts.google.com/o/oauth2/v2/auth?client_id=1&redirect_uri=x",
                            "https://login.microsoftonline.com/common", "https://id.other.org/oauth/authorize",
                            "https://user:secret@other.org/", "mailto:someone@other.org", "file:///etc/hosts", "about:blank"] {
            #expect(BrowserPeekRouting.decide(request(to: destination), settings: defaults) == .decline, "\(destination)")
        }
        #expect(BrowserPeekRouting.decide(request(to: "https://zoom.us/pricing"), settings: defaults) == .peek(.pinnedSourceLeavingSite))
        #expect(BrowserPeekRouting.decide(request(to: "https://meet.google.com/x", modifiers: [.shift]), settings: defaults) == .decline)
        // Sign-in flows are excluded before Shift-click is considered.
        #expect(BrowserPeekRouting.decide(request(to: "https://accounts.google.com/signin", modifiers: [.shift]),
                                          settings: defaults) == .decline)
        #expect(BrowserPeekRouting.decide(request(to: "https://other.org/login/oauth/authorize", modifiers: [.shift]),
                                          settings: defaults) == .decline)
    }

    @Test("Sites are registrable domains from the Public Suffix List")
    func sites() {
        func site(_ string: String) -> String? { BrowserPeekRouting.site(of: URL(string: string)!) }
        #expect(site("https://a.b.example.com/x") == "example.com")
        #expect(site("https://www.example.com") == "example.com")
        #expect(site("https://news.bbc.co.uk") == "bbc.co.uk")
        #expect(site("https://x.co.uk") == "x.co.uk")
        #expect(site("https://y.co.uk") != site("https://x.co.uk"))
        #expect(site("http://127.0.0.1:8080/") == "127.0.0.1")
        #expect(site("http://localhost:8080/") == "localhost")
        #expect(site("https://Example.COM.") == "example.com")
        #expect(site("https://alice.github.io/") != site("https://bob.github.io/"))
        #expect(site("https://b.test.ck/") == "b.test.ck")
        #expect(site("https://www.ck/") == "www.ck")
        // A Pinned github.io page links to another user's page: another site, so Peek.
        #expect(BrowserPeekRouting.decide(request(from: "https://alice.github.io/a", to: "https://bob.github.io/b"),
                                          settings: defaults) == .peek(.pinnedSourceLeavingSite))
        #expect(BrowserPeekRouting.decide(request(from: "https://alice.github.io/a", to: "https://alice.github.io/b"),
                                          settings: defaults) == .decline)
    }
}
