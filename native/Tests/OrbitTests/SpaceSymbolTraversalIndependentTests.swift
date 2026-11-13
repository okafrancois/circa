import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

/// Baseline-compatible replacement contract. The historical assertion file stays byte-identical.
extension NativeWebKitTests {
@Suite("Independent Space symbol traversal", .serialized)
@MainActor
struct SpaceSymbolTraversalIndependentTests {
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    @Test("Both modes keep search enabled and reachable through native forward and reverse key-view traversal")
    func enabledSearchTraversal() throws {
        let picker = SpaceIconPicker(currentIcon: "🧪", accent: .defaultSpace)
        picker.loadViewIfNeeded()
        let window = SymbolReviewHiddenWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false
        window.contentView = picker.view
        defer { window.close() }
        for mode in [SpaceIconPicker.Mode.emoji, .icons, .emoji] {
            picker.modes.selectedSegment = mode.rawValue
            #expect(picker.modes.sendAction(picker.modes.action, to: picker.modes.target))
            #expect(picker.search.isEnabled)
            #expect(picker.modes.nextKeyView === picker.search)
            #expect(picker.modes.nextValidKeyView === picker.search)
            #expect(window.makeFirstResponder(picker.modes))
            window.selectNextKeyView(picker.modes)
            let editor = try #require(picker.search.currentEditor() as? NSTextView)
            #expect(window.firstResponder === editor)
            #expect(!picker.control(picker.search, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
            #expect(!picker.control(picker.search, textView: editor, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
            let previous = picker.search.previousValidKeyView
            window.selectPreviousKeyView(picker.search)
            if let previous, previous !== picker.search {
                #expect(window.firstResponder === previous || (previous as? NSControl)?.currentEditor() === window.firstResponder)
            } else {
                #expect(picker.search.currentEditor() != nil)
                #expect(!NSApplication.shared.isFullKeyboardAccessEnabled)
            }
            #expect(!window.isVisible)
        }
    }

    @Test("Icons search replaces emoji results and Return commits at most once")
    func enabledSearchBehavior() {
        let picker = SpaceIconPicker(currentIcon: "🧪", accent: .defaultSpace)
        picker.loadViewIfNeeded()
        picker.modes.selectedSegment = SpaceIconPicker.Mode.icons.rawValue
        #expect(picker.modes.sendAction(picker.modes.action, to: picker.modes.target))
        picker.setSearch("briefcase")
        #expect(picker.search.isEnabled)
        #expect(picker.visibleItems.count == 1)
        #expect(picker.visibleItems.allSatisfy { $0.emoji.isEmpty })
        picker.setSearch("unfindablezzzz")
        var graphemes: [String] = []
        picker.onChoose = { graphemes.append($0) }
        #expect(picker.handle(#selector(NSResponder.insertNewline(_:))))
        #expect(graphemes.isEmpty && picker.canPresent)
        picker.cancel()
        #expect(!picker.canPresent && picker.popup.window == nil)
    }
}
}

/// Refuse before AppKit can order any test window or attach a panel/sheet.
@MainActor
final class SymbolReviewHiddenWindow: NSWindow {
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        precondition(place == .out, "Independent symbol test must never order a window")
        super.order(place, relativeTo: otherWin)
    }
    override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
        preconditionFailure("Independent symbol test must never attach a panel")
    }
    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        preconditionFailure("Independent symbol test must never present a sheet")
    }
}
