import AppKit
import Testing
@testable import Orbit

/// No controller, engine, profile, persisted session, visible window, or app activation.
@MainActor
private final class PaletteViewHarness {
    let view = BrowserPaletteView(frame: NSRect(x: 0, y: 0, width: 1024, height: 640))
    let window: NSWindow
    var accepted: [NSEvent.ModifierFlags] = []
    var moves: [Int] = []
    var selected: [Int] = []
    var queries: [String] = []
    var dismissCount = 0

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.isHidden = false
        view.onAccept = { [weak self] in self?.accepted.append($0) }
        view.onMove = { [weak self] in self?.moves.append($0) }
        view.onSelect = { [weak self] in self?.selected.append($0) }
        view.onQuery = { [weak self] in self?.queries.append($0) }
        view.onDismiss = { [weak self] in self?.dismissCount += 1 }
        view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(view.input)
    }

    var table: NSTableView { view.scroll.documentView as! NSTableView }
    func editor() throws -> NSTextView { try #require(view.input.currentEditor() as? NSTextView) }
    func render(_ results: [BrowserPaletteResult], selected: Int = 0) {
        view.render(results, selected: selected)
        view.layoutSubtreeIfNeeded()
    }
    func key(_ code: UInt16 = 36, flags: NSEvent.ModifierFlags = [], characters: String = "\r") throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    func close() { window.close() }
}

private func paletteViewResult(_ index: Int, section: BrowserPaletteSection = .history, title: String? = nil) -> BrowserPaletteResult {
    .init(id: "synthetic-\(index)", title: title ?? "Synthetic result \(index)", detail: "result-\(index).test",
          section: section, action: .navigate(URL(string: "https://result-\(index).test/")!))
}

extension NativeWebKitTests {
@Suite("Native palette reusable view", .serialized)
@MainActor
struct NativePaletteViewTests {
    @Test("Measured header and compact result geometry keep theme selection and real 16 point favicons")
    func measuredDailyGeometry() throws {
        let h = PaletteViewHarness()
        defer { h.close() }
        let favicon = NSImage(size: NSSize(width: 16, height: 16))
        h.view.accent = .systemPurple
        h.view.favicons = ["synthetic-0": favicon]
        h.render([paletteViewResult(0, section: .tabs)])
        let cell = try #require(h.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PaletteResultCell)
        cell.layoutSubtreeIfNeeded()
        #expect(h.view.input.frame.minX == 52)
        #expect(h.view.searchIcon.frame.midX == 31)
        #expect(h.view.divider.frame.minX == 10)
        #expect(h.view.panel.bounds.height - h.view.divider.frame.minY == 64)
        #expect(cell.iconTile.frame.size == NSSize(width: 24, height: 24))
        #expect(cell.icon.frame.size == NSSize(width: 16, height: 16))
        #expect(cell.titleLabel.frame.midY == cell.detailLabel.frame.midY)
        #expect(cell.titleLabel.frame.maxX < cell.detailLabel.frame.minX)
        #expect(cell.detailLabel.stringValue == "result-0.test")
        #expect(cell.actionLabel.stringValue == "Switch to Tab" && !cell.actionLabel.isHidden)
        #expect(cell.titleLabel.textColor == .white && cell.actionLabel.textColor == .white)
        #expect(cell.background.layer?.backgroundColor == NSColor.systemPurple.resolvedCGColor(for: cell.effectiveAppearance))
        #expect(cell.icon.contentTintColor == nil)
        for size in [NSSize(width: 1024, height: 640), NSSize(width: 1512, height: 949)] {
            let panel = BrowserPaletteView.panelFrame(in: size)
            #expect(panel.width == 765 && panel.midX == size.width / 2)
            #expect(panel.minY == size.height / 2 - 168.5)
        }
    }

    @Test("Native rows expose selection and section semantics while the input keeps its field editor")
    func sectionsSelectionAndFocus() throws {
        let h = PaletteViewHarness()
        defer { h.close() }
        let editor = try h.editor()
        h.render([paletteViewResult(0, section: .tabs), paletteViewResult(1, section: .history), paletteViewResult(2)])
        #expect(h.table.numberOfRows == 3)
        #expect(h.table.selectedRow == 0)
        #expect(h.table.style == .plain)
        #expect(h.table.rect(ofRow: 0).minY == 0)
        #expect(h.table.rect(ofRow: 0).height == OrbitTokens.Metrics.CommandBar.rowPitch)
        #expect(!h.table.acceptsFirstResponder)
        #expect(!h.view.tableView(h.table, isGroupRow: 1))
        #expect(h.view.tableView(h.table, shouldSelectRow: 1))
        #expect(h.table.rowView(atRow: 0, makeIfNecessary: true)?.accessibilityRole() == .row)
        #expect(h.table.rowView(atRow: 1, makeIfNecessary: true)?.accessibilityRole() == .row)
        h.view.updateSelection(2)
        #expect(h.table.selectedRow == 2)
        let row = try #require(h.table.rowView(atRow: 2, makeIfNecessary: true))
        #expect(row.accessibilityIdentifier() == "palette-result-2")
        #expect(row.accessibilityLabel() == "Synthetic result 2, History, result-2.test")
        #expect(row.isSelected)
        #expect(h.window.firstResponder === editor)
        #expect(!h.window.isVisible && !h.window.isKeyWindow)
        h.render([])
        #expect(h.table.numberOfRows == 0 && h.table.selectedRow == -1)
        #expect(h.window.firstResponder === editor)
    }

    @Test("Accessibility announces selection immediately and debounces asynchronous result counts")
    func announcementDebounce() async throws {
        let h = PaletteViewHarness()
        defer { h.close() }
        var announcements: [String] = []
        h.view.onAccessibilityAnnouncement = { announcements.append($0) }
        h.render((0..<3).map { paletteViewResult($0) })
        #expect(announcements.count == 1 && announcements[0].contains("Synthetic result 0"))
        h.render((0..<4).map { paletteViewResult($0) })
        h.render((0..<5).map { paletteViewResult($0) })
        #expect(announcements.count == 1)
        await h.view.waitForAccessibilityAnnouncements()
        #expect(announcements == ["Synthetic result 0, History, result-0.test, 1 of 3", "5 results"])
        h.render((0..<6).map { paletteViewResult($0) })
        h.view.updateSelection(1)
        #expect(announcements.last?.contains("Synthetic result 1") == true)
        let count = announcements.count
        await h.view.waitForAccessibilityAnnouncements()
        #expect(announcements.count == count)
        h.render([])
        await h.view.waitForAccessibilityAnnouncements()
        #expect(announcements.last == "0 results")
    }

    @Test("Query rendering preserves materialized cells and predecoded image identities")
    func cellsAndIconsAreReused() throws {
        let h = PaletteViewHarness()
        defer { h.close() }
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        h.view.favicons = ["synthetic-0": icon]
        h.render((0..<5).map { paletteViewResult($0) })
        let cell = try #require(h.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let row = try #require(h.table.rowView(atRow: 0, makeIfNecessary: true))
        let imageView = try #require(cell.subviews.compactMap { $0 as? NSImageView }.first)
        #expect(imageView.image === icon)
        h.render((0..<5).map { paletteViewResult($0, title: "Updated result \($0)") }, selected: 1)
        #expect(h.table.view(atColumn: 0, row: 0, makeIfNecessary: true) === cell)
        #expect(h.table.rowView(atRow: 0, makeIfNecessary: true) === row)
        #expect(imageView.image === icon)
        #expect(row.accessibilityLabel()?.contains("Updated result 0") == true)
        #expect(cell.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Updated result 0" })
        h.render((0..<4).map { paletteViewResult($0) })
        #expect(h.table.view(atColumn: 0, row: 0, makeIfNecessary: true) === cell)
        #expect(h.table.rowView(atRow: 0, makeIfNecessary: true) === row)
        h.view.favicons = [:]
        h.render((0..<5).map { paletteViewResult($0) })
        #expect(imageView.image !== icon)
        #expect(imageView.image != nil && imageView.contentTintColor != nil)
    }

    @Test("Prepared offscreen rows refresh their text, icons and accessibility labels before scrolling")
    func preparedOffscreenRows() throws {
        let h = PaletteViewHarness()
        defer { h.close() }
        h.render((0..<40).map { paletteViewResult($0) })
        let rowIndex = 8
        let cell = try #require(h.table.view(atColumn: 0, row: rowIndex, makeIfNecessary: true))
        _ = h.table.rowView(atRow: rowIndex, makeIfNecessary: true)
        h.render((0..<40).map { paletteViewResult($0, title: "Replacement \($0)") })
        h.view.updateSelection(rowIndex)
        h.view.layoutSubtreeIfNeeded()
        let row = try #require(h.table.rowView(atRow: rowIndex, makeIfNecessary: true))
        let currentCell = try #require(h.table.view(atColumn: 0, row: rowIndex, makeIfNecessary: true))
        #expect(currentCell === cell)
        #expect(row.accessibilityLabel()?.contains("Replacement 8") == true)
        #expect(currentCell.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Replacement 8" })
    }

    @Test("Mouse and accessibility activation use compact result indices without moving focus")
    func rowActivation() throws {
        let h = PaletteViewHarness()
        defer { h.close() }
        let editor = try h.editor()
        h.render([paletteViewResult(0, section: .tabs), paletteViewResult(1), paletteViewResult(2)])
        let row = try #require(h.table.rowView(atRow: 1, makeIfNecessary: true))
        #expect(row.accessibilityPerformPress())
        #expect(h.selected == [1])
        #expect(h.table.selectedRow == 1)
        #expect(h.window.firstResponder === editor)
        let rect = h.table.rect(ofRow: 2)
        let location = h.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                   windowNumber: h.window.windowNumber, context: nil, eventNumber: 1,
                                                   clickCount: 1, pressure: 1))
        h.table.mouseDown(with: click)
        #expect(h.selected == [1, 2])
        #expect(h.table.selectedRow == 2)
        #expect(h.window.firstResponder === editor)
        #expect(!h.window.isVisible)
    }

    @Test("Actual Return, Option-Return and Control-Return events use field-editor commands without newlines")
    func fieldEditorReturnEvents() throws {
        let h = PaletteViewHarness()
        defer { h.close() }
        let editor = try h.editor()
        for flags: NSEvent.ModifierFlags in [[], .option, .control] {
            editor.string = "synthetic query"
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            let previous = h.accepted.count
            editor.keyDown(with: try h.key(flags: flags, characters: flags.contains(.control) ? "\n" : "\r"))
            #expect(h.accepted.count == previous + 1)
            #expect(h.accepted.last?.intersection([.command, .option, .control]) == flags)
            #expect(editor.string == "synthetic query")
            #expect(h.window.firstResponder === editor)
        }
        #expect(!h.window.isVisible && !h.window.isKeyWindow)
    }

    @Test("Real Command-Return reaches the window key-equivalent path and preserves modifier flags")
    func commandReturnEvent() throws {
        let h = PaletteViewHarness()
        defer { h.close() }
        let editor = try h.editor()
        editor.string = "synthetic query"
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        #expect(h.window.performKeyEquivalent(with: try h.key(flags: flags)))
        #expect(h.accepted.count == 1)
        #expect(h.accepted.last?.intersection([.command, .shift]) == flags)
        #expect(editor.string == "synthetic query")
        #expect(h.window.firstResponder === editor)
        // The control also handles a directly delivered event and keypad Enter.
        h.view.input.keyDown(with: try h.key(76, flags: .command, characters: "\u{3}"))
        #expect(h.accepted.count == 2 && h.accepted.last?.contains(.command) == true)
        #expect(editor.string == "synthetic query")
    }

    @Test("Arrow, Tab, Backtab and Escape NSEvents are routed from the active editor")
    func editorNavigationEvents() throws {
        let h = PaletteViewHarness()
        defer { h.close() }
        let editor = try h.editor()
        editor.keyDown(with: try h.key(125, characters: "\u{f701}"))
        editor.keyDown(with: try h.key(126, characters: "\u{f700}"))
        editor.keyDown(with: try h.key(48, characters: "\t"))
        editor.keyDown(with: try h.key(48, flags: .shift, characters: "\u{19}"))
        #expect(h.moves == [1, -1, 1, -1])
        editor.keyDown(with: try h.key(53, characters: "\u{1b}"))
        #expect(h.dismissCount == 1)
        #expect(h.window.firstResponder === editor)
    }

    @Test("Marked text declines Return variants and key equivalents until the composition is committed")
    func compositionSafety() throws {
        let h = PaletteViewHarness()
        defer { h.close() }
        let editor = try h.editor()
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                         #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.moveDown(_:)),
                         #selector(NSResponder.cancelOperation(_:))] {
            #expect(!h.view.control(h.view.input, textView: editor, doCommandBy: selector))
        }
        #expect(!h.view.performKeyEquivalent(with: try h.key(flags: .command)))
        h.view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: h.view.input))
        #expect(h.accepted.isEmpty && h.moves.isEmpty && h.dismissCount == 0 && h.queries.isEmpty)
        #expect(editor.hasMarkedText())
        editor.unmarkText()
        #expect(h.window.performKeyEquivalent(with: try h.key(flags: .command)))
        #expect(h.accepted.count == 1)
    }

    @Test("Filtering keeps the input position stable, fits short lists and scrolls long lists")
    func fixedGeometryAndScrolling() {
        let h = PaletteViewHarness()
        defer { h.close() }
        h.render((0..<40).map { paletteViewResult($0) }, selected: 39)
        let frame = h.view.panel.frame
        #expect(h.table.selectedRow == 39)
        #expect(h.table.visibleRect.intersects(h.table.rect(ofRow: 39)))
        h.render([paletteViewResult(0)])
        #expect(h.view.panel.frame.minY == frame.minY && h.view.panel.frame.width == frame.width)
        #expect(h.view.panel.frame.height == BrowserPaletteView.panelFrame(in: h.view.bounds.size, resultCount: 1).height)
        let m = OrbitTokens.Metrics.CommandBar.self
        #expect(frame.width == m.width && frame.minY == m.top)
        #expect(frame.height == m.searchRowHeight + m.firstRowGap + 5 * m.rowPitch - (m.rowPitch - m.rowHeight) + m.bottomPadding)
    }

    @Test("Warm synchronous render plus layout stays below 8 ms at p95 across filtering and sections")
    func renderAndLayoutLatency() {
        let h = PaletteViewHarness()
        defer { h.close() }
        // Prepare synthetic queries outside the measured view-only interval.
        let batches = (0..<120).map { iteration in
            let count = [40, 28, 12, 5, 1, 0][iteration % 6]
            return (0..<count).map { index in
                paletteViewResult(index, section: index < 3 ? .tabs : .history,
                                  title: "Synthetic query \(iteration), result \(index)")
            }
        }
        for batch in batches.prefix(12) { h.render(batch) }
        let clock = ContinuousClock()
        var durations: [Double] = []
        durations.reserveCapacity(batches.count)
        for batch in batches {
            let start = clock.now
            h.render(batch)
            let duration = start.duration(to: clock.now)
            durations.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
        }
        durations.sort()
        let p95 = durations[Int(ceil(Double(durations.count) * 0.95)) - 1]
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        print("PALETTE_VIEW_BENCH render_layout_p95_ms=\(p95) samples=\(durations.count) rows=0...40 hidden=true configuration=\(configuration)")
        #expect(p95 < 8)
        #expect(!h.window.isVisible && !h.window.isKeyWindow)
    }
}
}
