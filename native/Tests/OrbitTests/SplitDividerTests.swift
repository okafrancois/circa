import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct SplitDividerTests {
    @Test("The full gap is interactive while the rounded grip stays centered at 2 by 24 points")
    func hitRegionAndCursor() throws {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 1002, height: 929))
        let divider = BrowserSplitDividerView(index: 0)
        divider.frame = CGRect(x: 496, y: 0, width: 10, height: 929)
        parent.addSubview(divider)
        #expect(divider.handleRect == CGRect(x: 4, y: 452.5, width: 2, height: 24))
        #expect(divider.interactionRect == divider.bounds)
        #expect(divider.resizeCursor === NSCursor.resizeLeftRight)
        divider.resetCursorRects()
        for point in [CGPoint(x: 496.01, y: 1), CGPoint(x: 501, y: 464.5), CGPoint(x: 505.99, y: 928)] {
            #expect(divider.hitTest(point) === divider)
        }
        #expect(divider.hitTest(CGPoint(x: 495.99, y: 464.5)) == nil)
        #expect(divider.hitTest(CGPoint(x: 506.01, y: 464.5)) == nil)
        divider.orientation = .vertical
        #expect(divider.resizeCursor === NSCursor.resizeUpDown)
    }

    @Test("Pointer events resize live and release retains the displayed geometry until publication")
    func liveDragAndRelease() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1002, height: 929),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = BrowserSplitView(frame: CGRect(x: 0, y: 0, width: 1002, height: 929))
        window.contentView = view
        let left = TabID(), right = TabID()
        let group = BrowserSplitGroup(tabIDs: [left, right])
        let leftHost = NSView(), rightHost = NSView()
        let panes: [BrowserSplitView.Pane] = [.init(id: left, view: leftHost, address: "Left"),
                                            .init(id: right, view: rightHost, address: "Right")]
        view.present(group, panes: panes, active: left, accent: .defaultPurple)
        view.layoutSubtreeIfNeeded()
        let divider = try #require(view.dividers.first)
        var commits: [[Double]] = []
        view.onResize = { commits.append($0) }
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 464.5),
                modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        divider.mouseDown(with: try event(.leftMouseDown, x: 501))
        divider.mouseDragged(with: try event(.leftMouseDragged, x: 589))
        #expect(view.panes[left]?.frame.width == 584)
        #expect(view.panes[right]?.frame.width == 408)
        #expect(commits.isEmpty)
        divider.mouseUp(with: try event(.leftMouseUp, x: 677))
        #expect(commits.count == 1)
        #expect(abs((view.panes[left]?.frame.width ?? 0) - 672) < 0.000001)
        #expect(abs((view.panes[right]?.frame.width ?? 0) - 320) < 0.000001)
        #expect(view.group?.ratios == commits.first)
        // A synchronous presentation between mouse-up and the store's publication cannot snap back.
        view.layoutSubtreeIfNeeded()
        #expect(abs((view.panes[left]?.frame.width ?? 0) - 672) < 0.000001)
        let committed = try #require(view.group)
        view.present(committed, panes: panes, active: left, accent: .defaultPurple)
        view.layoutSubtreeIfNeeded()
        #expect(abs((view.panes[left]?.frame.width ?? 0) - 672) < 0.000001)
        #expect(leftHost.superview != nil && rightHost.superview != nil)
        #expect(!window.isVisible)
    }

    @Test("Hover entry uses a finite ease-out without changing the grip geometry")
    func hoverTiming() {
        let timing = BrowserSplitTokens.dividerHoverTiming
        #expect(timing.duration == 0.15)
        #expect(abs(timing.progress(after: 0.075) - 0.875) < 0.000001)
        #expect(timing.progress(after: 0.15) == 1)
    }

    @Test("Pointer ratio math preserves the gap and existing minimum, including tiny layouts")
    func ratiosAndClamping() {
        let ratio = BrowserSplitGeometry.resized([0.5, 0.5], divider: 0, delta: 176, available: 992)
        let layout = BrowserSplitGeometry.layout(in: CGRect(x: 0, y: 0, width: 1002, height: 929),
                                                orientation: .horizontal, ratios: ratio)
        #expect(layout.panes[0].width == 672)
        #expect(layout.panes[1].width == 320)
        #expect(layout.dividers[0].width == 10)
        for delta: CGFloat in [-10000, 10000] {
            let clamped = BrowserSplitGeometry.resized([0.5, 0.5], divider: 0, delta: delta, available: 992)
            #expect(abs(clamped.min()! * 992 - 120) < 0.000001)
            #expect(abs(clamped.reduce(0, +) - 1) < 0.000001)
            #expect(BrowserSplitGeometry.resized([0.5, 0.5], divider: 0, delta: delta, available: 100) == [0.5, 0.5])
        }
    }
}
