import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct NativeSplitEventTests {
    @Test("Real mouse events through the local monitor focus the clicked pane inside an offset unflipped parent",
          arguments: [BrowserSplitOrientation.horizontal, .vertical])
    func monitorCoordinates(orientation: BrowserSplitOrientation) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let parent = NSView(frame: .init(x: 0, y: 0, width: 600, height: 550))
        window.contentView = parent
        let split = BrowserSplitView(frame: .init(x: 70, y: 90, width: 420, height: 350))
        parent.addSubview(split)
        let first = TabID(), second = TabID()
        let host = SplitMouseConsumer(frame: .zero)
        split.present(.init(tabIDs: [first, second], orientation: orientation),
            panes: [.init(id: first, view: host, address: "First"),
                    .init(id: second, view: NSView(), address: "Second")], active: second, accent: .defaultPurple)
        window.contentView?.layoutSubtreeIfNeeded()
        let pane = try #require(split.panes[first])
        pane.layoutSubtreeIfNeeded()
        var focused: [TabID] = []
        split.onFocus = { focused.append($0) }
        // The consumer swallows mouseDown, so a parent responder cannot mask a broken monitor.
        let location = host.convert(.init(x: 15, y: 15), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        NSApplication.shared.sendEvent(event)
        #expect(focused == [first])
        #expect(!window.isVisible)
    }
}

@MainActor
private final class SplitMouseConsumer: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
}
