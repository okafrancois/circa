import Foundation
import Testing
@testable import BrowserCore

struct GmailPreviewTests {
    @Test("Mail preview links retain the selected account and reject foreign hosts or malformed selectors")
    func accountRouting() throws {
        let account = try #require(BrowserGmailAccount(url: URL(string: "https://mail.google.com/mail/u/1/#inbox")!))
        #expect(account.selector == "1")
        #expect(account.feedURL.absoluteString == "https://mail.google.com/mail/u/1/feed/atom")
        #expect(account.composeURL.fragment == "inbox?compose=new")
        #expect(account.messageURL(id: "abcdef")?.absoluteString == "https://mail.google.com/mail/u/1/#inbox/abcdef")
        #expect(account.messageURL(id: "../sent?compose=new") == nil)
        #expect(account != BrowserGmailAccount(url: URL(string: "https://gmail.com/")!))
        #expect(BrowserGmailAccount(url: URL(string: "https://mail.google.com/mail/u/0/?authuser=2")!)?.selector == "2")
        #expect(BrowserGmailAccount(url: URL(string: "https://mail.google.com/mail/ca/u/1/")!) == account)
        for raw in ["http://mail.google.com/mail/u/0/", "https://mail.google.com.evil.test/mail/u/0/",
                    "https://user:password@mail.google.com/mail/u/0/", "https://mail.google.com:444/mail/u/0/",
                    "https://gmail.com/unexpected", "https://mail.google.com/mail/u/", "https://mail.google.com/mail/?authuser",
                    "https://mail.google.com/mail/?authuser=0&authuser=1", "https://mail.google.com/mail/x/u/1/"] {
            #expect(BrowserGmailAccount(url: URL(string: raw)!) == nil)
        }
    }

    private func entry(_ id: String = "abcdef") -> String {
        """
        <entry><title>One &amp; Two</title><summary>Plain &lt;safe&gt; text</summary>
        <id>tag:gmail.google.com,2004:\(id)</id><issued>2026-11-03T12:00:00Z</issued>
        <author><name>Synthetic Sender</name><email>sender@example.test</email></author></entry>
        """
    }

    private func feed(_ contents: String) -> Data {
        Data("<feed xmlns=\"http://purl.org/atom/ns#\">\(contents)</feed>".utf8)
    }

    @Test("A valid inbox preserves unread totals, safe text and message identity without persisting mail")
    func validFeed() throws {
        let inbox = try BrowserGmailInbox.decodeFeed(feed("<fullcount>1</fullcount>" + entry()))
        #expect(inbox.unreadCount == 1 && inbox.messages.count == 1)
        let message = try #require(inbox.messages.first)
        #expect(message.id == "abcdef" && message.sender == "Synthetic Sender")
        #expect(message.subject == "One & Two" && message.summary == "Plain <safe> text")
        #expect(message.receivedAt != nil)
        #expect(try BrowserGmailInbox.decodeFeed(feed("<fullcount>0</fullcount>")).messages.isEmpty)
        let many = try BrowserGmailInbox.decodeFeed(feed("<fullcount>22</fullcount>" + (1...22).map { entry(String($0, radix: 16)) }.joined()))
        #expect(many.unreadCount == 22 && many.messages.count == 20)
    }

    @Test("Sign-in pages, inconsistent totals, duplicate identities and XML entities cannot become an empty inbox")
    func invalidResponses() {
        let invalid = [Data("<html><body>Sign in</body></html>".utf8), feed(""), feed("<fullcount>3</fullcount>"),
            feed("<fullcount>0</fullcount>" + entry()), feed("<fullcount>2</fullcount>" + entry() + entry()),
            feed("<fullcount>-1</fullcount>"), feed("<fullcount>0</fullcount><fullcount>0</fullcount>"),
            feed("<fullcount>1</fullcount>" + entry("../../invalid")), Data(repeating: 32, count: 262_145),
            Data("<!DOCTYPE feed [<!ENTITY x SYSTEM 'file:///synthetic/not-read'>]><feed xmlns='http://purl.org/atom/ns#'><fullcount>0</fullcount></feed>".utf8)]
        for data in invalid {
            #expect(throws: BrowserGmailPreviewError.invalidResponse) { try BrowserGmailInbox.decodeFeed(data) }
        }
    }
}
