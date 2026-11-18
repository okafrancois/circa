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

    private func entry(_ id: String = "abcdef", links: String = "") -> String {
        """
        <entry><title>One &amp; Two</title><summary>Plain &lt;safe&gt; text</summary>
        <id>tag:gmail.google.com,2004:\(id)</id>\(links)<issued>2026-11-03T12:00:00Z</issued>
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

    private func link(_ href: String) -> String {
        "<link rel='alternate' type='text/html' href='\(href.replacingOccurrences(of: "&", with: "&amp;"))'/>"
    }

    @Test("The Atom alternate link supplies the conversation while the favorite supplies the account")
    func conversationLink() throws {
        let account = try #require(BrowserGmailAccount(url: URL(string: "https://mail.google.com/mail/u/2/")!))
        let href = "http://mail.google.com/mail?account_id=person@example.test&message_id=19a72Bc&view=conv&extsrc=atom"
        let home = link("https://mail.google.com/mail?message_id=123&view=conv")
        let inbox = try BrowserGmailInbox.decodeFeed(feed("<fullcount>2</fullcount>" + home
            + entry("1298971088706490756", links: link(href)) + entry("abcdef")))
        let message = try #require(inbox.messages.first)
        #expect(message.id == "1298971088706490756")
        #expect(account.messageURL(for: message)?.absoluteString ==
            "https://mail.google.com/mail/u/2/?message_id=19a72bc&view=conv&extsrc=atom")
        #expect(account.messageURL(for: inbox.messages[1]) == nil)
    }

    @Test("Invalid or ambiguous Atom links leave no conversation destination")
    func invalidConversationLinks() throws {
        let account = try #require(BrowserGmailAccount(url: URL(string: "https://mail.google.com/mail/u/0/")!))
        let route = "https://mail.google.com/mail?view=conv&message_id="
        for links in [
            link("https://mail.google.com/mail"),
            link("https://mail.google.com.example.test/mail?view=conv&message_id=abc"),
            link("https://identity@mail.google.com/mail?view=conv&message_id=abc"),
            link("https://mail.google.com/mail/feed/atom?view=conv&message_id=abc"),
            link(route + "abc&message_id=def"),
            link(route + "abc&view=conv"),
            link(route + "abc%2Finbox"),
            link(route + "abc") + link(route + "def")
        ] {
            let inbox = try BrowserGmailInbox.decodeFeed(feed("<fullcount>1</fullcount>" + entry(links: links)))
            #expect(account.messageURL(for: try #require(inbox.messages.first)) == nil)
        }
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

    @Test("Unread badge choices persist per profile and older preferences retain their default")
    func badgePreferences() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/gmail-preferences-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("settings.json")
        let first = ProfileID(), second = ProfileID(), tab = TabID()
        let store = try BrowserSettingsStore(destination: destination)
        try await store.updateProfile(first) { $0.hiddenGmailBadges.insert(tab) }
        let restored = try BrowserSettingsStore(destination: destination)
        let snapshot = await restored.snapshot()
        #expect(snapshot.profile(first).hiddenGmailBadges == [tab])
        #expect(snapshot.profile(second).hiddenGmailBadges.isEmpty)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserProfileSettings())) as? [String: Any])
        legacy.removeValue(forKey: "hiddenGmailBadges")
        #expect(try JSONDecoder().decode(BrowserProfileSettings.self, from: JSONSerialization.data(withJSONObject: legacy)).hiddenGmailBadges.isEmpty)
    }
}
