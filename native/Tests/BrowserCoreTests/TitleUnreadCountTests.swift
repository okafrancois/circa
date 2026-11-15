import BrowserCore
import Testing

struct TitleUnreadCountTests {
    @Test("Leading unread counts support round and square brackets", arguments: [
        ("(3) Inbox", 3), ("(12) Slack", 12), ("(99+) Inbox", 99),
        ("[3] Inbox", 3), ("[99+] Inbox", 99), ("(003) Inbox", 3),
        ("(12) 📬 Messages", 12), ("\u{200F}\u{00A0}(3) البريد", 3),
        ("\n\t[\u{202F}12\u{202F}] Inbox", 12), ("\u{2067}(3)\u{2069} البريد", 3),
        ("(99999999999999999999999999999999+) Inbox", Int.max)
    ])
    func positive(_ title: String, _ expected: Int) {
        #expect(BrowserTitleUnreadCount.parse(title) == expected)
    }

    @Test("Empty, zero, malformed and non-leading counts have no badge", arguments: [
        "", "Inbox", "Inbox (3)", "📬 (3) Inbox", "(0) Inbox", "[000] Inbox", "(0+) Inbox",
        "(-3) Inbox", "(+3) Inbox", "(3.5) Inbox", "(3,000) Inbox", "(3] Inbox", "(3 Inbox",
        "(+) Inbox", "(3++) Inbox", "(1 2) Inbox", "(٣) Inbox", "(💌) Inbox"
    ])
    func absent(_ title: String) { #expect(BrowserTitleUnreadCount.parse(title) == nil) }

    @Test func missingTitle() { #expect(BrowserTitleUnreadCount.parse(nil) == nil) }
}
