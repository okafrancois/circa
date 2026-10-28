import Foundation
import Testing
@testable import BrowserCore

@Suite("Portable bookmark HTML")
struct BrowserBookmarkHTMLTests {
    @Test("Nested folders, empty folders, Unicode and escaped titles and URLs round-trip exactly")
    func roundtrip() throws {
        let document = BrowserBookmarkDocument(entries: [
            .folder(title: "Travail & recherche 🧪", children: [
                .link(title: "A <B> & \"C\" 'D'", url: URL(string: "https://example.test/?x=1&y=2")!),
                .folder(title: "Empty", children: []),
                .folder(title: "Nested", children: [.link(title: "Équipe", url: URL(string: "http://example.test/team")!)])
            ])
        ])
        let data = try BrowserBookmarkHTML.encode(document)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("A &lt;B&gt; &amp; &quot;C&quot; &#39;D&#39;"))
        #expect(text.contains("?x=1&amp;y=2"))
        #expect(try BrowserBookmarkHTML.decode(data) == document)
        #expect(document.linkCount == 2)
    }

    @Test("Common Netscape DT/P formatting, mixed-case tags and quoted or unquoted attributes work")
    func conventionalFormatting() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
        <dl><p>
        <DT><H3 ADD_DATE="123">Folder</H3>
        <DL><p>
        <dt><a ADD_DATE='123' href=https://example.test/path?q=one&x=two>Title</a>
        </DL><p>
        </DL><p>
        """
        let decoded = try BrowserBookmarkHTML.decode(Data(html.utf8))
        #expect(decoded.entries == [.folder(title: "Folder", children: [
            .link(title: "Title", url: URL(string: "https://example.test/path?q=one&x=two")!)
        ])])
    }

    @Test("Unsupported, relative, privileged and embedded-credential links are counted rather than imported")
    func unsupportedLinks() throws {
        let links = ["javascript:alert(1)", "data:text/html,unsafe", "chrome://settings", "chrome-extension://id/page",
                     "file:///private/tmp/sample", "/relative", "https://user:secret@example.test/", "https://example.test/good"]
        let html = "<DL>" + links.map { "<DT><A HREF='\($0)'>Entry</A>" }.joined() + "</DL>"
        let decoded = try BrowserBookmarkHTML.decode(Data(html.utf8))
        #expect(decoded.skippedLinkCount == 7)
        #expect(decoded.linkCount == 1)
        #expect(decoded.entries == [.link(title: "Entry", url: URL(string: "https://example.test/good")!)])
    }

    @Test("Numeric entities decode once and exported markup never becomes a link or folder")
    func entitiesAndMarkup() throws {
        let text = "<DL><A HREF='https://example.test/?x=1&#38;y=2'>&#x1F9EA; &#233; &amp;lt;A&amp;gt;</A></DL>"
        let document = try BrowserBookmarkHTML.decode(Data(text.utf8))
        #expect(document.entries == [.link(title: "🧪 é &lt;A&gt;", url: URL(string: "https://example.test/?x=1&y=2")!)])
        let maliciousTitle = "</A><A HREF='https://other.test'>Other"
        let safe = BrowserBookmarkDocument(entries: [.link(title: maliciousTitle, url: URL(string: "https://example.test")!)])
        #expect(try BrowserBookmarkHTML.decode(BrowserBookmarkHTML.encode(safe)) == safe)
    }

    @Test("Malformed hierarchy and ambiguous repeated attributes refuse without flattening or partial results")
    func malformedStructure() {
        for text in ["", "<DL>", "</DL>", "<DL><H3>Folder</H3></DL>", "<DL><DL></DL></DL>",
                     "<DL><A HREF='https://example.test'>Incomplete</DL>",
                     "<DL><A HREF='https://one.test' href='https://two.test'>Ambiguous</A></DL>",
                     "<DL></DL><DL></DL>", "<!-- unterminated"] {
            #expect(throws: BrowserBookmarkTransferError.self) { try BrowserBookmarkHTML.decode(Data(text.utf8)) }
        }
    }

    @Test("Comments and external declarations are inert; UTF-8 decoding is strict")
    func noExternalResolution() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1 SYSTEM "https://unresolvable.invalid/external.dtd">
        <!-- <DL><A HREF='https://hidden.test'>Ignored</A></DL> -->
        <DL><A HREF='https://example.test'>Visible</A></DL>
        """
        #expect(try BrowserBookmarkHTML.decode(Data(html.utf8)).linkCount == 1)
        #expect(throws: BrowserBookmarkTransferError.invalidEncoding) { try BrowserBookmarkHTML.decode(Data([0xff])) }
    }

    @Test("Deep input, oversized tokens and oversized files refuse at explicit resource bounds")
    func boundedInput() {
        let deep = "<DL>" + String(repeating: "<H3>Folder</H3><DL>", count: BrowserBookmarkHTML.maximumDepth + 1)
        #expect(throws: BrowserBookmarkTransferError.excessiveDepth) { try BrowserBookmarkHTML.decode(Data(deep.utf8)) }
        let token = "<DL><A HREF='" + String(repeating: "a", count: 65_537) + "'>Title</A></DL>"
        #expect(throws: BrowserBookmarkTransferError.oversized) { try BrowserBookmarkHTML.decode(Data(token.utf8)) }
        #expect(throws: BrowserBookmarkTransferError.oversized) {
            try BrowserBookmarkHTML.decode(Data(repeating: 32, count: BrowserBookmarkHTML.maximumBytes + 1))
        }
    }

    @Test("Export rejects unsafe URLs even when constructed without using the decoder")
    func exportValidation() {
        for value in ["javascript:alert(1)", "file:///private/tmp/item", "https://user:secret@example.test"] {
            let document = BrowserBookmarkDocument(entries: [.link(title: "Entry", url: URL(string: value)!)])
            #expect(throws: BrowserBookmarkTransferError.invalidURL) { try BrowserBookmarkHTML.encode(document) }
        }
    }
}
