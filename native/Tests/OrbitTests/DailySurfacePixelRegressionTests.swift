import AppKit
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Recovered daily surface pixel regressions", .serialized)
@MainActor
struct DailySurfacePixelRegressionTests {
    @Test("The Library shares the window background and receives input", arguments: [false, true])
    func libraryBackdrop(dark: Bool) throws {
        let view = BrowserLibraryView(frame: NSRect(x: 0, y: 0, width: 420, height: 668))
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        // A single window fill prevents seams between Library content and the surrounding shell.
        view.appearance = appearance
        view.acceptsLibraryInput = true
        view.select(.downloads, theme: .default)
        view.layoutSubtreeIfNeeded()
        #expect(view.railBackground.frame == NSRect(x: 0, y: 0, width: 112, height: 668))
        #expect(view.body.layer?.backgroundColor == nil)
        #expect(view.hitTest(NSPoint(x: 10, y: 300)) != nil)
    }

    @Test("A compact row measures short detail text before and after native layout",
          arguments: ["⌘N", "Current profile", "Chrome Web Store", "Switch to Tab"])
    func initialDetailWidth(detail: String) {
        let cell = PaletteResultCell(frame: NSRect(x: 0, y: 0, width: 700, height: 46))
        // command-bar-2026-10-27.md: commands use shortcut accessories; page rows retain details.
        cell.configure(result: .init(id: "history", title: "New Window", detail: detail, section: .history,
                                    action: .navigate(URL(string: "https://palette.test/")!)), image: nil, usesFavicon: false)
        for _ in 0..<3 { cell.needsLayout = true; cell.layoutSubtreeIfNeeded() }
        let text = (cell.detailLabel.stringValue as NSString).size(withAttributes: [.font: cell.detailLabel.font!]).width
        #expect(cell.detailLabel.frame.width >= ceil(text) + 2)
        #expect(cell.titleLabel.frame.maxX < cell.detailLabel.frame.minX)
    }
}
}
