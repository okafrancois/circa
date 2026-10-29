import Testing
import AppKit
@testable import Orbit

struct BrowserTranslationTests {
    @Test("Status hit testing chooses its action control before URL editing")
    @MainActor func statusHitTarget() throws {
        let root = SidebarAddressField(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        let field = OrbitLocationField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 14)
        OrbitAddressFieldStyle.applySingleLine(to: field)
        root.installField(field)
        field.stringValue = "https://example.org/"
        field.onStatusPress = {}
        field.setStatus("Synthetic translation status", animated: false)
        root.layoutSubtreeIfNeeded()
        field.layoutSubtreeIfNeeded()
        let rect = field.statusAnchorRect
        for center in [NSPoint(x: rect.midX, y: rect.midY), NSPoint(x: rect.midX, y: rect.maxY - 0.5)] {
            let point = field.convert(center, to: root.superview)
            let hit = try #require(root.hitTest(point))
            #expect(hit is NSButton && hit.superview === field)
        }
        field.onStatusPress = nil
        let point = field.convert(NSPoint(x: rect.midX, y: rect.midY), to: root.superview)
        #expect(!(root.hitTest(point) is NSButton))
    }

    @Test func preferredLanguagesSuppressOffers() {
        var state = BrowserTranslationState()
        state.detect(source: "de-DE", preferred: ["en-US", "de-AT"], supported: true)
        #expect(state.phase == .unavailable)
        state.detect(source: "de", preferred: ["en-US"], supported: true)
        #expect(state.phase == .available)
        #expect(state.source == "de" && state.target == "en")
    }
    @Test func lifecycleAndRetry() {
        var state = BrowserTranslationState()
        let refused = state.begin()
        #expect(!refused)
        state.detect(source: "de", preferred: ["en"], supported: true)
        let started = state.begin()
        #expect(started)
        #expect(state.phase == .translating)
        let duplicate = state.begin()
        #expect(!duplicate)
        state.complete()
        #expect(state.phase == .translated)
        state.restore()
        #expect(state.phase == .original)
        let restarted = state.begin()
        #expect(restarted)
        state.fail()
        #expect(state.phase == .failed)
        let retried = state.begin()
        #expect(retried)
    }
    @Test func unavailableAndUnknownLanguages() {
        for source in [nil, "und", "mul", "zxx"] as [String?] {
            var state = BrowserTranslationState()
            state.detect(source: source, preferred: ["en"], supported: true)
            #expect(state.phase == .unavailable)
        }
        var state = BrowserTranslationState()
        state.detect(source: "de", preferred: ["en"], supported: false)
        #expect(state.phase == .unavailable)
        state.detect(source: "de", preferred: [], supported: true)
        #expect(state.phase == .unavailable)
        state.complete()
        #expect(state.phase == .unavailable)
    }
    @Test func languageDetectionUsesContent() {
        #expect(BrowserTranslationState.detectLanguage(text: "Ein Baum ist eine verholzte Pflanze mit einer Wurzel, einem Stamm und einer Krone. Die meisten Bäume haben viele grüne Blätter.", hint: "en") == "de")
        #expect(BrowserTranslationState.detectLanguage(text: "Hi", hint: "de") == nil)
    }
}
