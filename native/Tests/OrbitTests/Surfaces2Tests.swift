import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct Surfaces2Tests {
    @Test("Peek covers the sidebar and keeps its card anchored to the browser content")
    func peekWindowScrim() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { controller.session.close(); controller.window?.close() }
        controller.submitAddress("https://surfaces.test/source")
        await controller.session.waitForPendingCommands()
        _ = try #require(controller.openPeek(URL(string: "https://surfaces.test/peek")!))
        let root = try #require(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let overlay = controller.peekOverlay
        #expect(overlay.frame == root.bounds)
        let documentLeading = overlay.convert(controller.contentCard.bounds, from: controller.contentCard).minX
        #expect(overlay.presentationBounds == NSRect(x: documentLeading, y: 0,
            width: root.bounds.maxX - documentLeading, height: root.bounds.height))
        #expect(overlay.cardFrame.minX > controller.sidebar.frame.maxX)
        #expect(root.subviews.firstIndex(of: overlay)! > root.subviews.firstIndex(of: controller.sidebar)!)
        let point = NSPoint(x: controller.sidebar.frame.midX, y: controller.sidebar.frame.midY)
        #expect(root.hitTest(point) === overlay)
        overlay.onClickOutside?()
        #expect(!controller.isPeekPresented)
    }

    @Test("Little Orbit keeps the full editable URL while rendering its compact domain")
    func quickWindowAddressAndCopy() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let url = URL(string: "https://surfaces.test/a/path?query=synthetic#fragment")!
        let little = try await environment.makeQuickWindow(url: url)
        defer { environment.retireQuickWindows() }
        little.promotionShortcut = { "⌘O" }
        little.render()
        little.window?.contentView?.layoutSubtreeIfNeeded()
        let fieldRect = little.toolbar.convert(little.addressField.bounds, from: little.addressField)
        #expect(fieldRect.minY >= 0 && fieldRect.maxY <= little.toolbar.bounds.height)
        let trafficContainer = try #require(little.window?.standardWindowButton(.closeButton)?.superview?.superview)
        #expect(trafficContainer.frame.maxX <= little.addressField.frame.minX)
        #expect(little.addressField.stringValue == url.absoluteString)
        #expect(little.openButton.title == "Open in Personal")
        #expect(little.openButton.shortcut == "⌘O")
        var copied: URL?
        little.copyURLWriter = { copied = $0 }
        little.copyAddressButton.performClick(nil)
        #expect(copied == url)
        little.focusAddress()
        let input = try #require(little.compactInput)
        // Keep the application hidden while exercising the panel's real field editor.
        #expect(input.window.makeFirstResponder(input.input))
        input.input.selectText(nil)
        let editor = try #require(input.input.currentEditor() as? NSTextView)
        #expect(editor.string == url.absoluteString)
        #expect(editor.selectedRange() == NSRange(location: 0, length: url.absoluteString.utf16.count))
        #expect(little.isEditingAddress)
    }

    @Test("Split header actions target their own document and preserve the other pane")
    func splitHeaderRouting() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { controller.session.close(); controller.window?.close() }
        controller.submitAddress("https://surfaces.test/first")
        await controller.session.waitForPendingCommands()
        let left = try #require(controller.session.selectedSurface)
        controller.submitAddress("https://surfaces.test/second")
        await controller.session.waitForPendingCommands()
        controller.session.addSplitPane(url: URL(string: "https://surfaces.test/right")!)
        await controller.session.waitForPendingCommands()
        let right = try #require(controller.session.selectedSurface)
        let group = try #require(controller.session.activeSplit)
        let leftID = try #require(group.tabs.first { $0.occurrenceID == controller.session.occurrenceID(for: left) }?.id)
        let pane = try #require(controller.split.view.panes[leftID])
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(pane.convert(pane.back.bounds, from: pane.back).midY < 32)
        #expect(pane.page.frame.minY == 32)
        let trafficContainer = try #require(controller.window?.standardWindowButton(.closeButton)?.superview?.superview)
        #expect(trafficContainer.frame.maxX < controller.contentCard.frame.minX)
        #expect(pane.back.isEnabled)
        pane.back.performClick(nil)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface === left)
        #expect(left.currentURL?.path == "/first")
        #expect(right.currentURL?.path == "/right")
        #expect(pane.forward.isEnabled)
        pane.forward.performClick(nil)
        await controller.session.waitForPendingCommands()
        #expect(left.currentURL?.path == "/second")
        pane.close.performClick(nil)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.activeSplit == nil)
        #expect(controller.session.selectedSurface === right)
        #expect(!right.isDisposed)
    }
}
}
