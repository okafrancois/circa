import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
@testable import Orbit

/// NAV-INITIATOR: links the shell takes out of their tab are reopened from their document by
/// engines that can (`BrowserLinkReopening`), so the request keeps that document as initiator; the
/// historical load by URL stays the fallback and the behaviour of engines that cannot.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NavigationInitiatorTests {
    private typealias Window = BrowserWindowController<PeekSyntheticEngine>

    private func makeWindow(_ address: String) async throws -> (Window, PeekSyntheticSurface) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment<PeekSyntheticEngine>(engine: PeekSyntheticEngine())
        let controller = try await environment.makeWindow()
        controller.submitAddress(address)
        await controller.session.waitForPendingCommands()
        return (controller, try #require(controller.session.selectedSurface))
    }

    private func settle(_ window: Window) async {
        for _ in 0..<3 {
            await window.session.waitForPendingCommands()
            for _ in 0..<5 { await Task.yield() }
        }
    }

    @Test("An Option-clicked link reaches the split as a new target of its document, not a load by URL")
    func optionClickReopensIntoSplit() async throws {
        let (window, tab) = try await makeWindow("https://split.test/left")
        defer { window.session.close(); window.window?.close() }
        tab.reopensLinksFromDocument = true
        let destination = URL(string: "https://other.test/target")!
        tab.clickLink(to: destination, modifiers: [.option])
        #expect(tab.currentURL?.path == "/left", "the tab never follows the Option-clicked link")
        await settle(window)
        #expect(tab.reopenedLinks.map(\.url) == [destination])
        #expect(tab.reopenedLinks.first?.modifiers == [.option])
        #expect(tab.openedTargets == [destination], "the split pane is the document's own new target")
        #expect(tab.reopenFallbacks == 0)
        #expect(window.session.activeSplit?.tabs.count == 2)
        let pane = try #require(window.session.selectedSurface)
        #expect(pane !== tab && pane.requestedURLs == [destination])
    }

    @Test("A reopen that never arrives falls back to the split load by URL, once")
    func optionClickFallsBackToSplitLoad() async throws {
        let (window, tab) = try await makeWindow("https://split.test/left")
        defer { window.session.close(); window.window?.close() }
        tab.reopensLinksFromDocument = true
        tab.dropsLinkReopens = true
        let destination = URL(string: "https://other.test/fallback")!
        tab.clickLink(to: destination, modifiers: [.option])
        await settle(window)
        #expect(tab.reopenFallbacks == 1 && tab.openedTargets.isEmpty)
        #expect(window.session.activeSplit?.tabs.count == 2)
        #expect(window.session.selectedSurface?.requestedURLs == [destination])
    }

    @Test("An engine without reopening keeps the historical split load")
    func optionClickWithoutReopening() async throws {
        let (window, tab) = try await makeWindow("https://split.test/left")
        defer { window.session.close(); window.window?.close() }
        tab.clickLink(to: URL(string: "https://other.test/plain")!, modifiers: [.option])
        await settle(window)
        #expect(tab.reopenedLinks.isEmpty && tab.openedTargets.isEmpty)
        #expect(window.session.activeSplit?.tabs.count == 2)
    }

    @Test("A Pinned tab's link to another site opens its Peek as a new target of the document")
    func pinnedLinkReopensIntoPeek() async throws {
        let (window, tab) = try await makeWindow("https://app.example.com/inbox")
        defer { window.window?.close() }
        window.peek.sourceClassifier = { _ in (.pinned, nil) }
        tab.reopensLinksFromDocument = true
        let loads = tab.sentRequests.count
        let destination = URL(string: "https://other.org/plain")!
        tab.clickLink(to: destination)
        await settle(window)
        #expect(tab.currentURL?.path == "/inbox" && tab.sentRequests.count == loads)
        #expect(tab.reopenedLinks.map(\.url) == [destination] && tab.openedTargets == [destination])
        let peeked = try #require(window.presentedPeekSurface)
        #expect(peeked.requestedURLs == [destination])
        #expect(window.peek.presentation?.trigger == .pinnedSourceLeavingSite)
        #expect(window.session.ownedSurfaces.count == 1)
    }

    @Test("A Shift-clicked link keeps its trigger through the reopen, and falls back to a Peek by URL")
    func shiftClickReopensIntoPeek() async throws {
        let (window, tab) = try await makeWindow("https://app.example.com/inbox")
        defer { window.window?.close() }
        tab.reopensLinksFromDocument = true
        tab.clickLink(to: URL(string: "https://other.org/story")!, modifiers: [.shift])
        await settle(window)
        #expect(window.peek.presentation?.trigger == .shiftClick)
        #expect(tab.openedTargets.count == 1)
        window.dismissPeek()
        await settle(window)
        tab.dropsLinkReopens = true
        tab.clickLink(to: URL(string: "https://other.org/second")!, modifiers: [.shift])
        await settle(window)
        #expect(tab.reopenFallbacks == 1 && tab.openedTargets.count == 1)
        #expect(window.presentedPeekSurface?.requestedURLs == [URL(string: "https://other.org/second")!])
    }
}
}

@Suite("Link reopen ledger")
struct BrowserLinkReopenLedgerTests {
    @Test("A reopen is consumed by its own request, whatever the engine's URL spelling")
    func takesMatchingRequest() {
        var ledger = BrowserLinkReopenLedger()
        let id = ledger.begin(url: URL(string: "HTTPS://Other.Test")!, modifiers: [.option], disposition: .newForegroundTab)
        let other = ledger.take(url: "https://elsewhere.test/")
        #expect(other == nil, "another request is not the reopen")
        let entry = ledger.take(url: "https://other.test:443/")
        #expect(entry?.id == id && entry?.modifiers == [.option])
        let undelivered = ledger.finish(id)
        #expect(!undelivered, "a delivered reopen needs no fallback")
    }

    @Test("An undelivered reopen asks for its fallback exactly once")
    func undeliveredFallsBack() {
        var ledger = BrowserLinkReopenLedger()
        let id = ledger.begin(url: URL(string: "https://a.test/x?q=1")!, modifiers: [.shift], disposition: .newWindow)
        let other = ledger.take(url: "https://a.test/x?q=2")
        #expect(other == nil, "query is part of the target")
        let first = ledger.finish(id), second = ledger.finish(id)
        #expect(first && !second)
        #expect(ledger.pendingCount == 0)
    }

    @Test("The ledger stays bounded; pushed-out entries still get their fallback")
    func bounded() {
        var ledger = BrowserLinkReopenLedger()
        let first = ledger.begin(url: URL(string: "https://a.test/0")!, modifiers: [], disposition: .newForegroundTab)
        for index in 1...BrowserLinkReopenLedger.capacity {
            _ = ledger.begin(url: URL(string: "https://a.test/\(index)")!, modifiers: [], disposition: .newForegroundTab)
        }
        #expect(ledger.pendingCount == BrowserLinkReopenLedger.capacity)
        let stale = ledger.take(url: "https://a.test/0")
        #expect(stale == nil, "a pushed-out reopen no longer matches")
        let owed = ledger.finish(first), again = ledger.finish(first)
        #expect(owed && !again)
    }
}
