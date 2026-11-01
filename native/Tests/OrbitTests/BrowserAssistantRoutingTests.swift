import AppKit
import Testing
import BrowserCore
@testable import Orbit

struct BrowserAssistantRoutingTests {
    @Test func questionsRemainSeparateFromNavigation() {
        let resolver = AddressResolver()
        #expect(BrowserPaletteQuestion.matches("How does caching work?", resolver: resolver))
        #expect(BrowserPaletteQuestion.matches("what is an actor", resolver: resolver))
        #expect(!BrowserPaletteQuestion.matches("https://example.com/why?", resolver: resolver))
        #expect(!BrowserPaletteQuestion.matches("example.com", resolver: resolver))
        #expect(!BrowserPaletteQuestion.matches("cached favicon", resolver: resolver))
    }
}

@MainActor struct BrowserAssistantGeometryTests {
    @Test func dockTimingHasExactEndpointsAndFastOpening() {
        #expect(BrowserAssistantMotion.progress(0, opening: true) < 0.0001)
        #expect(BrowserAssistantMotion.progress(1, opening: true) > 0.9999)
        #expect(BrowserAssistantMotion.progress(0.5, opening: true) > 0.9)
    }
}

extension BrowserAssistantGeometryTests {
    @Test func dockNarrowsExistingPageAndCloseRestoresIt() async throws {
        let card = BrowserContentCardView()
        card.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let page = NSView()
        card.present(page)
        card.layoutSubtreeIfNeeded()
        let fullWidth = page.frame.width
        let panel = NSView()
        card.setAssistant(panel, width: 372)
        try? await Task.sleep(for: .milliseconds(500))
        card.layoutSubtreeIfNeeded()
        #expect(card.isPresenting(page))
        #expect(abs(page.frame.width - (fullWidth - 382)) < 1)
        #expect(abs(panel.frame.width - 372) < 1)
        let start = NSPoint(x: panel.frame.minX - 5, y: 200)
        let grip = try #require(card.hitTest(start))
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: start.y),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        grip.mouseDown(with: try mouse(.leftMouseDown, start.x))
        grip.mouseDragged(with: try mouse(.leftMouseDragged, start.x - 200))
        #expect(abs(panel.frame.width - 480) < 1)
        #expect(abs(page.frame.width - (fullWidth - 490)) < 1)
        grip.mouseDragged(with: try mouse(.leftMouseDragged, start.x + 800))
        grip.mouseUp(with: try mouse(.leftMouseUp, start.x + 800))
        #expect(abs(panel.frame.width - 300) < 1)
        #expect(abs(page.frame.width - (fullWidth - 310)) < 1)
        card.setAssistant(nil, width: 0)
        try? await Task.sleep(for: .milliseconds(350))
        card.layoutSubtreeIfNeeded()
        #expect(card.isPresenting(page))
        #expect(abs(page.frame.width - fullWidth) < 1)
        #expect(panel.superview == nil)
    }
}
