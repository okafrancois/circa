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
        // The reveal starts at zero width, but the chat keeps its destination text layout.
        #expect(panel.bounds.width == 372)
        let panelClip = try #require(panel.superview)
        #expect(panelClip !== card)
        #expect(panelClip.layer?.masksToBounds == true)
        try? await Task.sleep(for: .milliseconds(500))
        card.layoutSubtreeIfNeeded()
        #expect(card.isPresenting(page))
        #expect(abs(page.frame.width - (fullWidth - 382)) < 1)
        #expect(abs(panel.frame.width - 372) < 1)
        let pageClip = try #require(page.superview)
        #expect(abs(pageClip.frame.maxX + 10 - card.convert(panel.bounds, from: panel).minX) < 1)
        #expect(abs(pageClip.bounds.width - page.frame.width) < 1)
        #expect(abs(card.pageViewportSize.width - page.frame.width) < 1)
        #expect(pageClip.layer?.masksToBounds == true)
        #expect(pageClip.layer?.cornerRadius == card.cornerRadius)
        let border = try #require(card.subviews.first { $0 is OrbitSurfaceBackgroundView })
        #expect(border.frame == pageClip.frame)
        let header = NSView()
        card.setHeader(header)
        card.layoutSubtreeIfNeeded()
        #expect(header.frame.width == pageClip.bounds.width)
        #expect(card.pageViewportSize.height == pageClip.bounds.height - card.headerHeight)
        card.setHeader(nil)
        card.layoutSubtreeIfNeeded()
        let start = NSPoint(x: card.convert(panel.bounds, from: panel).minX - 5, y: 200)
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

struct BrowserAssistantModelTests {
    @Test func metadataKeepsRequestIdentifiersAndSupportedEfforts() {
        let model = BrowserAIModel(provider: .codex, id: "gpt-6.1-sol", displayName: "gpt-6.1-sol",
            efforts: ["low", "high"], defaultEffort: "low")
        #expect(BrowserAssistantModels.name(model) == "GPT 6.1 Sol")
        let previous = BrowserAIModelChoice(provider: .codex, model: "other", effort: "ultra")
        let selected = BrowserAssistantModels.selecting(model, previous: previous)
        #expect(selected.model == model.id)
        #expect(selected.effort == "low")
        #expect(BrowserAssistantModels.selecting(model, previous: .init(provider: .codex, model: "other", effort: "high")).effort == "high")
        let status = BrowserAIProviderStatus(id: .codex, state: .signedOut, models: [model])
        #expect(BrowserAssistantModels.models(.codex, choices: [selected, selected], statuses: [.codex: status]) == [model])
        #expect(BrowserAssistantModels.models(.claudeCode, choices: [selected], statuses: [.codex: status]).isEmpty)
    }
    @Test func popoverUsesWindowWidthAndKeepsReadableColumns() {
        #expect(BrowserAssistantModels.pickerWidth(windowWidth: 1000) == 560)
        #expect(BrowserAssistantModels.pickerWidth(windowWidth: 500) == 460)
        #expect(BrowserAssistantModels.pickerWidth(windowWidth: 400) == 360)
    }
}
