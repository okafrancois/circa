import Foundation
import Testing
@testable import BrowserCore

@Suite("Bookmark encoding resource symmetry")
struct BrowserBookmarkEncodingBoundsTests {
    @Test("Export refuses escaped text and URL tokens its own decoder cannot accept")
    func escapedTokenBounds() {
        let title = String(repeating: "&", count: 16_000)
        let url = URL(string: "https://bounds.test/")!
        for entry in [BrowserBookmarkDocument.Entry.link(title: title, url: url), .folder(title: title, children: [])] {
            #expect(throws: BrowserBookmarkTransferError.oversized) {
                try BrowserBookmarkHTML.encode(.init(entries: [entry]))
            }
        }
        let expanded = URL(string: "https://bounds.test/?" + String(repeating: "&", count: 16_000))!
        #expect(throws: BrowserBookmarkTransferError.oversized) {
            try BrowserBookmarkHTML.encode(.init(entries: [.link(title: "Bounded", url: expanded)]))
        }
    }

    @Test("Both decoding and encoding refuse more than 50,000 entries")
    func entryBounds() {
        let entry = BrowserBookmarkDocument.Entry.link(title: "Synthetic", url: URL(string: "https://bounds.test/")!)
        #expect(throws: BrowserBookmarkTransferError.excessiveEntries) {
            try BrowserBookmarkHTML.encode(.init(entries: Array(repeating: entry, count: BrowserBookmarkHTML.maximumEntries + 1)))
        }
        let html = "<DL>" + String(repeating: "<A HREF='https://bounds.test/'>Synthetic</A>", count: BrowserBookmarkHTML.maximumEntries + 1) + "</DL>"
        #expect(throws: BrowserBookmarkTransferError.excessiveEntries) { try BrowserBookmarkHTML.decode(Data(html.utf8)) }
    }
}
