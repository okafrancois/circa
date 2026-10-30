import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Little toolbar cursor and copy", .serialized)
@MainActor
struct QuickWindowToolbarTests {
    @Test("Only the uncovered address area registers a text cursor after resizing")
    func cursorGeometry() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let little = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.invalid/path")!)
        defer { environment.retireQuickWindows() }
        let window = try #require(little.window)
        for name in ["Personal", "A longer synthetic Space name"] {
            little.updateDestinationName("Personal", sourceName: name)
            for width in [480, 640, 960, 1280, 480] {
                window.setContentSize(NSSize(width: width, height: 480))
                window.contentView?.layoutSubtreeIfNeeded()
                let regions = little.addressField.textCursorRects
                for button in [little.sourceSpaceBadge, little.extensionsButton, little.copyAddressButton,
                               little.openButton, little.spaceButton] {
                    #expect(button.bounds.contains(button.arrowCursorRect))
                    #expect(!button.arrowCursorRect.isEmpty)
                    let rect = little.addressField.convert(button.arrowCursorRect, from: button)
                    #expect(regions.allSatisfy { !$0.intersects(rect) }, "control=\(button.accessibilityLabel() ?? button.title) rect=\(rect) regions=\(regions)")
                    #expect(little.toolbar.hitTest(little.toolbar.superview!.convert(
                        NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)) === button)
                }
                #expect(regions.allSatisfy { little.addressField.bounds.contains($0) && !$0.isEmpty })
                if width >= 640 { #expect(!regions.isEmpty) }
            }
        }
        little.sourceSpaceBadge.isHidden = true
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(little.addressField.textCursorRects.contains { $0.minX == little.addressField.visibleRect.minX })
        #expect(!window.isVisible)
    }

    @Test("Toolbar and command copy the live URL, preserving query, fragment and encoding")
    func copyCurrentDocument() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let first = URL(string: "https://synthetic.invalid/first")!
        let current = URL(string: "https://synthetic.invalid/a%20path?query=a%26b#fragment")!
        let little = try await environment.makeQuickWindow(url: first)
        defer { environment.retireQuickWindows() }
        var copied: [URL] = []
        little.copyURLWriter = { copied.append($0) }
        let surface = try #require(little.surface)
        surface.navigate(to: current)
        little.addressField.stringValue = first.absoluteString
        little.copyAddressButton.performClick(nil)
        little.copyURL()
        #expect(copied == [current, current])
        #expect(surface.requestedURLs == [first, current])
        #expect(little.beginPromotionPreparation())
        little.copyAddressButton.performClick(nil)
        little.copyURL()
        #expect(copied.count == 2)
        little.endPromotionPreparation()
        surface.dispose()
        little.copyAddressButton.performClick(nil)
        little.copyURL()
        #expect(copied.count == 2)
        little.retire()
        little.copyAddressButton.performClick(nil)
        #expect(copied.count == 2)
    }

    @Test("An empty Little document does not overwrite the clipboard")
    func emptyDocument() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let little = try await environment.makeQuickWindow()
        defer { environment.retireQuickWindows() }
        var writes = 0
        little.copyURLWriter = { _ in writes += 1 }
        little.copyAddressButton.performClick(nil)
        little.copyURL()
        #expect(writes == 0)
    }

    @Test("The native link writer supplies both text and URL representations on a private board")
    func nativePasteboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let url = URL(string: "https://synthetic.invalid/a%20path?query=1#fragment")!
        #expect(BrowserLinkPasteboard.write(url, to: board))
        #expect(board.string(forType: .string) == url.absoluteString)
        #expect(board.string(forType: .URL) == url.absoluteString)
    }

    @Test("Copy feedback has localized text, fixed window insets and bounded timing")
    func copyFeedbackGeometry() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let little = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.invalid/copy")!)
        defer { environment.retireQuickWindows() }
        let window = try #require(little.window)
        let toast = little.copiedToast
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        little.copyURLWriter = { BrowserLinkPasteboard.write($0, to: board) }
        window.setContentSize(NSSize(width: 800, height: 360))
        window.contentView?.layoutSubtreeIfNeeded()
        little.copyAddressButton.performClick(nil)
        let root = try #require(window.contentView)
        #expect(toast.superview === root)
        let copyPoint = root.convert(NSPoint(x: little.copyAddressButton.bounds.midX,
                                            y: little.copyAddressButton.bounds.midY), from: little.copyAddressButton)
        #expect(toast.hitTest(copyPoint) == nil)
        #expect(toast.hitTest(root.convert(NSPoint(x: toast.shareButton.bounds.midX,
                                                  y: toast.shareButton.bounds.midY), from: toast.shareButton)) === toast.shareButton)
        #expect(toast.label.stringValue == "Copied Current URL")
        #expect(toast.accessibilityLabel() == toast.label.stringValue)
        #expect(toast.frame.size == NSSize(width: 205, height: 48))
        #expect(root.bounds.maxX - toast.frame.maxX == 4)
        #expect(root.isFlipped ? toast.frame.minY == 8 : root.bounds.maxY - toast.frame.maxY == 8)
        #expect(BrowserQuickWindowCopyFeedback.fadeInDuration == TimeInterval(1) / 15)
        #expect(BrowserQuickWindowCopyFeedback.visibleDuration == 4.88)
        #expect(BrowserQuickWindowCopyFeedback.fadeOutDuration == 0)
        #expect(BrowserQuickWindowCopyFeedback.dismissalDuration == 0.2)
        for scale in [CGFloat(0.01), 0.5, 1] {
            let transform = BrowserQuickWindowCopyFeedback.topAnchoredTransform(scale: scale)
            #expect(abs(48 * transform.m22 + transform.m42 - 48) < 0.001)
            #expect(abs(102.5 * transform.m11 + transform.m41 - 102.5) < 0.001)
        }
        #expect(board.string(forType: .string) == "https://synthetic.invalid/copy")
        #expect(board.string(forType: .URL) == board.string(forType: .string))
        window.setContentSize(NSSize(width: 960, height: 480))
        root.layoutSubtreeIfNeeded()
        #expect(root.bounds.maxX - toast.frame.maxX == 4)
        #expect(root.isFlipped ? toast.frame.minY == 8 : root.bounds.maxY - toast.frame.maxY == 8)
        little.retire()
        #expect(toast.superview == nil)
    }

    @Test("Repeated copy restarts feedback without letting an earlier dismissal remove it")
    func repeatedCopyFeedback() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let little = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.invalid/repeated")!)
        defer { environment.retireQuickWindows() }
        var copies = 0
        little.copyURLWriter = { _ in copies += 1 }
        little.copyAddressButton.performClick(nil)
        let toast = little.copiedToast
        let first = toast.presentation
        try await Task.sleep(for: .milliseconds(250))
        little.copyURL()
        #expect(toast.presentation == first + 1)
        #expect(copies == 2)
        toast.dismiss(presentation: first)
        #expect(toast.superview != nil)
        try await Task.sleep(for: .seconds(BrowserQuickWindowCopyFeedback.visibleDuration - 0.2))
        #expect(toast.superview != nil)
        #expect(toast.alphaValue == 1)
        try await Task.sleep(for: .seconds(0.2 + BrowserQuickWindowCopyFeedback.dismissalDuration + 0.4))
        #expect(toast.superview == nil)
        little.copyAddressButton.performClick(nil)
        #expect(toast.superview != nil && toast.alphaValue == 1)
        toast.dismiss(presentation: toast.presentation)
        #expect(toast.superview == nil && toast.alphaValue == 1)
    }

    @Test("Main sidebar toolbar and address accessories do not overlap the text cursor")
    func mainSidebarCursorGeometry() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        owner.submitAddress("https://synthetic.invalid/main")
        await owner.session.waitForPendingCommands()
        let sidebar = owner.sidebar
        sidebar.addressContainer.holdsAccessoriesVisible = true
        for width in [CGFloat(228), 312, 500, 228] {
            sidebar.setFrameSize(NSSize(width: width, height: 640))
            for _ in 0..<3 { sidebar.layoutSubtreeIfNeeded() }
            let field = owner.addressField
            let cursor = field.convert(field.textCursorRect, to: sidebar)
            #expect(!cursor.isEmpty)
            func buttons(_ view: NSView) -> [NSButton] {
                view.subviews.flatMap { child in
                    if let button = child as? NSButton { return [button] }
                    return buttons(child)
                }
            }
            let controls = buttons(sidebar).filter { !$0.isHiddenOrHasHiddenAncestor }
            #expect(!controls.isEmpty)
            for button in controls {
                #expect(!cursor.intersects(sidebar.convert(button.bounds, from: button)))
            }
        }
        #expect(owner.window?.isVisible == false)
    }
}
}
