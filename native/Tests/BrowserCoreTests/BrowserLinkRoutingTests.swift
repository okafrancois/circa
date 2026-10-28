import Darwin
import Foundation
import Testing
@testable import BrowserCore

struct BrowserLinkRoutingTests {
    @Test("URL operators distinguish literal contains, exact URL and case insensitive host")
    func operators() {
        let space = SpaceID()
        let url = URL(string: "https://example.org/Report?next=other.org")!
        #expect(BrowserLinkRoute(value: "example.org", spaceID: space).matches(url))
        #expect(BrowserLinkRoute(value: "Report", spaceID: space).matches(url))
        #expect(!BrowserLinkRoute(value: "report", spaceID: space).matches(url))
        #expect(BrowserLinkRoute(match: .equals, value: url.absoluteString, spaceID: space).matches(url))
        #expect(!BrowserLinkRoute(match: .equals, value: "example.org", spaceID: space).matches(url))
        #expect(BrowserLinkRoute(match: .host, value: "EXAMPLE.ORG", spaceID: space).matches(url))
        #expect(!BrowserLinkRoute(match: .host, value: "other.org", spaceID: space).matches(url))
        #expect(!BrowserLinkRoute(value: "", spaceID: space).matches(url))
        #expect(!BrowserLinkRoute(value: "example.org", spaceID: space).matches(URL(string: "file:///example.org")!))
    }

    @Test("First available matching route wins and a missing destination falls back")
    func precedence() {
        let a = SpaceID(), b = SpaceID()
        var routing = BrowserLinkRouting()
        routing.rules = [.init(value: "example", spaceID: a), .init(value: "example.org", spaceID: b)]
        let url = URL(string: "https://example.org/")!
        #expect(routing.destination(for: url, availableSpaces: [a, b]) == .space(a))
        #expect(routing.destination(for: url, availableSpaces: [b]) == .space(b))
        #expect(routing.destination(for: url, availableSpaces: []) == .quickWindow)
        routing.defaultDestination = .space(a)
        #expect(routing.destination(for: URL(string: "https://other.org/")!, availableSpaces: [b]) == .mostRecentSpace)
    }

    @Test("Routes, edits, order, defaults and deletion survive reopening the actual settings file")
    func persistence() async throws {
        let canonical = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("Orbit-ATC-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let store = try BrowserSettingsStore(destination: file)
        let a = SpaceID(), b = SpaceID()
        let first = BrowserLinkRoute(value: "example", spaceID: a)
        var second = BrowserLinkRoute(value: "example.org", spaceID: b)
        try await store.saveLinkRoute(first)
        try await store.saveLinkRoute(second)
        second.match = .host
        try await store.saveLinkRoute(second)
        try await store.moveLinkRoute(second.id, offset: -1)
        try await store.setLinkDefaultDestination(.space(b))
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().linkRouting.rules == [second, first])
        #expect(await reopened.snapshot().linkRouting.defaultDestination == .space(b))
        #expect(await !reopened.snapshot().opensExternalLinksInQuickWindow)
        try await reopened.removeSpace(b)
        let cleaned = try await BrowserSettingsStore(destination: file).snapshot()
        #expect(cleaned.linkRouting.rules == [first])
        #expect(cleaned.linkRouting.defaultDestination == .mostRecentSpace)
        try await reopened.setOpensExternalLinksInQuickWindow(true)
        #expect(await reopened.snapshot().linkRouting.defaultDestination == .quickWindow)
        try await reopened.removeLinkRoute(first.id)
        #expect(await reopened.snapshot().linkRouting.rules.isEmpty)
    }

    @Test("Existing settings without routing retain their chosen Little Orbit behavior")
    func migration() throws {
        for quickWindow in [true, false] {
            var document = BrowserSettingsDocument()
            document.opensExternalLinksInQuickWindow = quickWindow
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
            object.removeValue(forKey: "linkRouting")
            let decoded = try JSONDecoder().decode(BrowserSettingsDocument.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(decoded.linkRouting.defaultDestination == (quickWindow ? .quickWindow : .mostRecentSpace))
            #expect(decoded.linkRouting.rules.isEmpty)
        }
    }

    @Test("Document edits keep both link preferences consistent through encoding")
    func documentRoundTrip() throws {
        var document = BrowserSettingsDocument()
        document.opensExternalLinksInQuickWindow = false
        #expect(document.linkRouting.defaultDestination == .mostRecentSpace)
        #expect(try JSONDecoder().decode(BrowserSettingsDocument.self, from: JSONEncoder().encode(document)) == document)
        let space = SpaceID()
        document.linkRouting.defaultDestination = .space(space)
        #expect(!document.opensExternalLinksInQuickWindow)
        #expect(document.linkRouting.defaultDestination == .space(space))
        #expect(try JSONDecoder().decode(BrowserSettingsDocument.self, from: JSONEncoder().encode(document)) == document)
        document.opensExternalLinksInQuickWindow = true
        #expect(document.linkRouting.defaultDestination == .quickWindow)
        #expect(try JSONDecoder().decode(BrowserSettingsDocument.self, from: JSONEncoder().encode(document)) == document)
    }
}
