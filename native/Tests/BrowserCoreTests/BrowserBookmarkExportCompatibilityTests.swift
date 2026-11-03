import Foundation
import Testing
@testable import BrowserCore

@Suite("Invented desktop bookmark exports")
struct BrowserBookmarkExportCompatibilityTests {
    // Handwritten synthetic exports: no account data, downloaded fixtures or remote icons.
    @Test("Chrome-shaped export keeps toolbar nesting, empty folders and siblings in source order")
    func chromeExport() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000200" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://catalog.example.test/?q=maps&amp;sort=date" ADD_DATE="1700000001" ICON="data:image/png;base64,AA==">Maps &amp; plans</A>
                <DT><H3 ADD_DATE="1700000002" LAST_MODIFIED="1700000003">Research &lt;2026&gt;</H3>
                <DL><p>
                    <DT><A HREF="https://catalog.example.test/notes" ADD_DATE="1700000003" ICON="data:image/png;base64,AA==">Notes — 東京</A>
                    <DT><H3 ADD_DATE="1700000004" LAST_MODIFIED="0">Later</H3>
                    <DL><p>
                    </DL><p>
                </DL><p>
                <DT><A HREF="http://archive.example.test/" ADD_DATE="1700000005">Archive</A>
            </DL><p>
            <DT><H3 ADD_DATE="1700000006" LAST_MODIFIED="0">Other bookmarks</H3>
            <DL><p>
                <DT><A HREF="https://garden.example.test/">Garden</A>
            </DL><p>
        </DL><p>
        """
        let document = try BrowserBookmarkHTML.decode(Data(html.utf8))
        #expect(document == BrowserBookmarkDocument(entries: [
            .folder(title: "Bookmarks bar", children: [
                .link(title: "Maps & plans", url: URL(string: "https://catalog.example.test/?q=maps&sort=date")!),
                .folder(title: "Research <2026>", children: [
                    .link(title: "Notes — 東京", url: URL(string: "https://catalog.example.test/notes")!),
                    .folder(title: "Later", children: [])
                ]),
                .link(title: "Archive", url: URL(string: "http://archive.example.test/")!)
            ]),
            .folder(title: "Other bookmarks", children: [
                .link(title: "Garden", url: URL(string: "https://garden.example.test/")!)
            ])
        ]))
    }

    @Test("Firefox-shaped export ignores descriptions and separators without moving links or relaxing URL policy")
    func firefoxExport() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks Menu</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000100" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar</H3>
            <DL><p>
                <DT><A HREF="https://atlas.example.test/?a=1&amp;b=2" ADD_DATE="1700000001" LAST_MODIFIED="1700000002" ICON_URI="https://atlas.example.test/favicon.ico" ICON="data:image/png;base64,AA==" SHORTCUTURL="atlas" TAGS="maps,field notes" LAST_CHARSET="UTF-8">Atlas &quot;field&quot;</A>
                <DD>Invented description with &lt;DL&gt; text, not a saved entry.
                <DT><HR>
                <DT><H3 ADD_DATE="1700000003" LAST_MODIFIED="1700000004">Field &#x1F9ED;</H3>
                <DD>Folder description
                <DL><p>
                    <DT><HR>
                    <DT><A HREF="place:sort=8&amp;maxResults=10" ADD_DATE="1700000005">Recent bookmarks</A>
                    <DT><A HREF="javascript:void(0)" ADD_DATE="1700000006">Synthetic bookmarklet</A>
                    <DT><A HREF="https://atlas.example.test/log?x=1&#38;y=2" ADD_DATE="1700000007">Day&#160;one &#233;</A>
                    <DT><HR>
                </DL><p>
                <DT><A HREF="https://atlas.example.test/after" ADD_DATE="1700000008">After folder</A>
            </DL><p>
            <HR>
            <DT><H3 ADD_DATE="1700000009" LAST_MODIFIED="0" UNFILED_BOOKMARKS_FOLDER="true">Other Bookmarks</H3>
            <DL><p>
                <DT><HR>
            </DL><p>
        </DL><p>
        """
        let document = try BrowserBookmarkHTML.decode(Data(html.utf8))
        #expect(document == BrowserBookmarkDocument(entries: [
            .folder(title: "Bookmarks Toolbar", children: [
                .link(title: "Atlas \"field\"", url: URL(string: "https://atlas.example.test/?a=1&b=2")!),
                .folder(title: "Field 🧭", children: [
                    .link(title: "Day\u{a0}one é", url: URL(string: "https://atlas.example.test/log?x=1&y=2")!)
                ]),
                .link(title: "After folder", url: URL(string: "https://atlas.example.test/after")!)
            ]),
            .folder(title: "Other Bookmarks", children: [])
        ], skippedLinkCount: 2))
    }

    @Test("Safari-shaped export accepts folded headings, explicit DT endings and CRLF indentation")
    func safariExport() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <HTML>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <Title>Bookmarks</Title>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 FOLDED>Favorites</H3>
            <DL><p>
                <DT><A HREF="https://studio.example.test/?label=%22draft%22&amp;v=2">Studio &amp; Co.</A></DT>
                <DT><H3 FOLDED>Reading &amp; ideas</H3>
                <DL><p>
                    <DT><A HREF="https://studio.example.test/read">A &lt; B &gt; C</A></DT>
                </DL><p>
                <DT><A HREF="https://studio.example.test/next">Next</A></DT>
            </DL><p>
            <DT><H3 FOLDED>Bookmarks Menu</H3>
            <DL><p>
                <DT><A HREF="https://studio.example.test/menu">Editor&apos;s picks</A></DT>
            </DL><p>
        </DL><p>
        </HTML>
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let document = try BrowserBookmarkHTML.decode(Data(html.utf8))
        #expect(document == BrowserBookmarkDocument(entries: [
            .folder(title: "Favorites", children: [
                .link(title: "Studio & Co.", url: URL(string: "https://studio.example.test/?label=%22draft%22&v=2")!),
                .folder(title: "Reading & ideas", children: [
                    .link(title: "A < B > C", url: URL(string: "https://studio.example.test/read")!)
                ]),
                .link(title: "Next", url: URL(string: "https://studio.example.test/next")!)
            ]),
            .folder(title: "Bookmarks Menu", children: [
                .link(title: "Editor's picks", url: URL(string: "https://studio.example.test/menu")!)
            ])
        ]))
    }
}
