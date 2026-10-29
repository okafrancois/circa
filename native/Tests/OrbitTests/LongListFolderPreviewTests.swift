import AppKit
import Testing
@testable import Orbit
@testable import BrowserCore

extension NativeWebKitTests {
@Suite("Long folder preview recycling", .serialized)
@MainActor
struct LongListFolderPreviewTests {
    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child -> [NSButton] in
            if let button = child as? NSButton, button.action == NSSelectorFromString("choose:") { return [button] }
            return buttons(in: child)
        }
    }

    private func visible(_ view: NSView) -> [NSButton] { buttons(in: view).filter { !$0.isHidden } }

    private func results(_ count: Int, fixture: SyntheticOrganization = SyntheticOrganization()) -> [FolderPreviewResult] {
        FolderPreviewResult.ordered((0..<count).map { fixture.tab(title: "Synthetic tab \($0)", url: "https://folder.test/\($0)") })
    }

    private func editor() -> NSTextView { NSTextView() }

    @Test("Five hundred results give buttons only to the rows near the viewport, at forty-point rows")
    func viewportRows() throws {
        let view = FolderPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 530))
        let items = results(500)
        view.render(items, image: { _ in nil })
        // The 446-point list area plus six rows of overscan on each side.
        #expect(view.materializedRowCount <= 26 && buttons(in: view).count <= 26)
        for button in visible(view) {
            #expect(button.frame == NSRect(x: 0, y: CGFloat(button.tag) * 40, width: view.scroll.contentSize.width, height: 40))
            #expect(button.attributedTitle.string.hasPrefix(items[button.tag].title))
        }
        let document = try #require(view.scroll.documentView)
        #expect(document.frame.height == CGFloat(500 * 40))
        for y in stride(from: 0, through: 19_000, by: 200) { view.scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(y))) }
        #expect(buttons(in: view).count <= 26, "scrolling reuses buttons")
        for button in visible(view) { #expect(button.attributedTitle.string.hasPrefix(items[button.tag].title)) }
    }

    @Test("Moving the keyboard selection redraws only the previous and the new row")
    func twoRowSelection() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 530), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = FolderPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 530))
        window.contentView?.addSubview(view)
        view.render(results(500), image: { _ in nil })
        #expect(view.control(view.search, textView: editor(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        for button in visible(view) { button.layer?.displayIfNeeded() }
        #expect(visible(view).allSatisfy { $0.layer?.needsDisplay() == false })
        #expect(view.control(view.search, textView: editor(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        let redrawn = visible(view).filter { $0.layer?.needsDisplay() == true }.map(\.tag).sorted()
        #expect(redrawn == [0, 1])
        #expect(visible(view).filter { $0.state == .on }.map(\.tag) == [1])
    }

    @Test("A tab that stays listed keeps its button; selection and scroll position follow live updates")
    func identityAcrossRenders() throws {
        let fixture = SyntheticOrganization()
        let view = FolderPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 530))
        let items = results(300, fixture: fixture)
        view.render(items, image: { _ in nil })
        for _ in 0..<31 { _ = view.control(view.search, textView: editor(), doCommandBy: #selector(NSResponder.moveDown(_:))) }
        let origin = view.scroll.contentView.bounds.origin
        #expect(origin.y > 0)
        let selected = try #require(visible(view).first { $0.state == .on })
        #expect(selected.tag == 30)
        // A live update inserts a tab above: the same tab keeps its button and its selection.
        let inserted = FolderPreviewResult.ordered([fixture.tab(title: "Synthetic new tab", url: "https://folder.test/new")]) + items
        view.render(inserted, image: { _ in nil })
        #expect(selected.state == .on && selected.tag == 31 && !selected.isHidden)
        #expect(selected.frame.minY == CGFloat(31 * 40))
        #expect(view.scroll.contentView.bounds.origin == origin)
        #expect(view.control(view.search, textView: editor(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(visible(view).filter { $0.state == .on }.map(\.tag) == [32])
        // Search results: inert rows first, then the filtered list reuses buttons.
        let before = buttons(in: view).count
        view.render([], image: { _ in nil })
        #expect(visible(view).isEmpty)
        view.render(Array(items.prefix(12)), image: { _ in nil })
        #expect(buttons(in: view).count == before && visible(view).count == 12)
        var chosen: [TabID] = []
        view.onChoose = { chosen.append($0) }
        let first = try #require(visible(view).first { $0.tag == 0 })
        first.performClick(nil)
        #expect(chosen == [items[0].tab.id])
    }

    @Test("Live image refreshes reach only rows with buttons")
    func refreshVisibleImages() {
        let view = FolderPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 530))
        var reads = 0
        view.render(results(500), image: { _ in reads += 1; return nil })
        reads = 0
        view.refreshImages()
        #expect(reads == view.materializedRowCount && reads <= 24)
        view.clear()
        #expect(buttons(in: view).isEmpty)
    }
}
}
