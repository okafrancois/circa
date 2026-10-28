import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Library sidebar panel", .serialized)
@MainActor
struct LibraryPanelTests {
    @Test("The rail follows Orbit destinations and leaves History on its menu command")
    func destinations() {
        #expect(BrowserLibraryCategory.railCategories == [.media, .downloads, .spaces, .boosts, .archive])
        let view = BrowserLibraryView()
        view.select(.downloads, theme: .lavender)
        #expect(view.categoryButtons[.downloads]?.state == .on)
        #expect(view.categoryButtons[.spaces]?.state == .off)
        #expect(view.categoryButtons[.history] == nil)
        view.select(.spaces, theme: .rosePlum)
        #expect(view.categoryButtons[.spaces]?.state == .on)
        #expect(view.categoryButtons[.downloads]?.state == .off)
        #expect(view.acceptsFirstResponder)
    }

    @Test("Easels is absent from the rail and every available destination")
    func easelsIsRemoved() {
        #expect(BrowserLibraryCategory.allCases.count == 6)
        #expect(BrowserLibraryCategory(rawValue: 6) == nil)
        let view = BrowserLibraryView()
        #expect(view.categoryButtons.count == 5)
        #expect(view.categoryButtons.values.allSatisfy { $0.accessibilityIdentifier() != "library-category-easels" })
        view.select(.media, theme: .default)
        #expect(BrowserLibraryMediaView().searchField.placeholderString == uiText("Search Media…"))
    }

    @Test("An outside click dismisses the panel and keeps the document event available")
    func outsideClick() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Library fixture")
        let space = try await store.createSpace(name: "Library fixture", profileID: profile)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space,
            engine: SiteSyntheticEngine(), onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close() }
        await controller.session.waitForPendingCommands()
        let surface = controller.session.selectedSurface
        controller.showLibrary(.downloads)
        await controller.session.waitForPendingCommands()
        #expect(controller.library.isPresented)
        controller.library.drawer.onOutsideClick?()
        #expect(!controller.library.isPresented)
        #expect(controller.session.selectedSurface === surface)
        #expect(!controller.contentCard.isHidden)
        controller.showLibrary(.downloads)
        await controller.session.waitForPendingCommands()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let panel = controller.library.view
        #expect(controller.contentCard.frame.minX >= panel.frame.maxX)
        controller.hideLibrary(focus: false)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.contentCard.frame.minX < panel.bounds.width)
    }

    @Test("Missing local media are honest empty destinations with working Escape")
    func emptyDestinations() {
        let view = BrowserLibraryView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        view.acceptsLibraryInput = true
        var returned = false
        view.onBack = { returned = true }
        for category in [BrowserLibraryCategory.media] {
            view.select(category, theme: .default)
            #expect(view.categoryButtons[category]?.state == .on)
            view.layoutSubtreeIfNeeded()
            #expect(view.body.frame.minX == BrowserLibraryView.railWidth)
        }
        view.cancelOperation(nil)
        #expect(returned)
    }

    @Test("The retained destinations keep Orbit's rail pitch, centred, and remain separate in a short window")
    func railLayout() throws {
        for height in [CGFloat(780), 400] {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 417, height: height))
            let view = BrowserLibraryView(frame: root.bounds)
            root.addSubview(view)
            root.layoutSubtreeIfNeeded()
            let frames = BrowserLibraryCategory.railCategories.compactMap { category in
                view.categoryButtons[category].map { view.convert($0.bounds, from: $0) }
            }.sorted { $0.minY < $1.minY }
            #expect(frames.count == 5)
            for (lower, upper) in zip(frames, frames.dropFirst()) { #expect(lower.maxY <= upper.minY + 0.5) }
            if height == 780 {
                let first = try #require(frames.first), last = try #require(frames.last)
                // Orbit's six-entry pitch (100 pt over its 580 pt span), group centred in that span.
                #expect(abs(first.minY - 155) < 0.5, "Rail frames: \(frames)")
                #expect(abs(last.maxY - 635) < 0.5)
                for (lower, upper) in zip(frames, frames.dropFirst()) { #expect(abs(upper.minY - lower.minY - 100) < 0.5) }
                #expect(frames.allSatisfy { abs($0.height - 80) < 0.5 && abs($0.width - 97) < 0.5 })
            }
            let back = try #require(view.subviews.first { $0.accessibilityIdentifier() == "library-back" })
            #expect(back.frame == NSRect(x: 8, y: 8, width: 32, height: 32))
            #expect(back.toolTip == uiText("Exit Library"))
        }
    }

    @Test("Empty searches preserve editing across projections and Escape clears before leaving")
    func emptySearchEditing() throws {
        let view = BrowserLibraryMediaView(frame: NSRect(x: 0, y: 0, width: 417, height: 780))
        let profile = ProfileID()
        view.render([], profile: profile)
        #expect(view.searchField.isEditable && view.searchField.isSelectable)
        view.searchField.stringValue = "Synthetic query"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        view.render([], profile: profile)
        #expect(view.searchField.stringValue == "Synthetic query")
        var exited = false
        view.onBack = { exited = true }
        let text = NSTextView()
        #expect(view.control(view.searchField, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(view.searchField.stringValue.isEmpty && !exited)
        #expect(view.control(view.searchField, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(exited)
        #expect(view.searchField.placeholderString == uiText("Search Media…"))
    }

    @Test("The native field editor stays inside the Library search text rectangle")
    func searchEditorGeometry() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let search = BrowserLibrarySearchField(frame: NSRect(x: 8, y: 20, width: 285, height: 36))
        window.contentView?.addSubview(search)
        #expect(window.makeFirstResponder(search))
        let editor = try #require(search.currentEditor() as? NSTextView)
        let frame = search.convert(editor.visibleRect, from: editor)
        // AppKit adds a 3-point horizontal editor inset and a small vertical selection margin.
        #expect(frame.minX >= 40 && frame.minY >= 6 && frame.maxY <= 32, "Native editor: \(frame)")
    }
}
}
