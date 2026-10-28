import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
@testable import Orbit

/// The optional `routeNavigations` hook: engines that report modified clicks as navigations of
/// the tab (WebKit) still open Shift-clicked links in Peek.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativePeekNavigationRouteTests {
    private func makeWindow() async throws -> (BrowserWindowController<PeekSyntheticEngine>, PeekSyntheticSurface) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment<PeekSyntheticEngine>(engine: PeekSyntheticEngine())
        let controller = try await environment.makeWindow()
        controller.submitAddress("https://app.example.com/inbox")
        await controller.session.waitForPendingCommands()
        return (controller, try #require(controller.session.selectedSurface))
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("A Shift-clicked link is cancelled in the tab and opens in Peek once, on the next turn")
    func shiftClickedNavigationOpensPeek() async throws {
        let (controller, tab) = try await makeWindow()
        defer { controller.window?.close() }
        let destination = URL(string: "https://other.org/story")!
        let loads = tab.requestedURLs
        tab.clickLink(to: destination, modifiers: [.shift])
        #expect(tab.requestedURLs == loads, "the tab never starts the shift-clicked load")
        #expect(tab.currentURL?.path == "/inbox")
        await settle()
        let peeked = try #require(controller.presentedPeekSurface)
        #expect(peeked.requestedURLs == [destination])
        #expect(controller.peek.presentation?.trigger == .shiftClick)
        #expect(controller.session.ownedSurfaces.count == 1)
    }

    @Test("A Pinned tab's plain click on a link to another site is cancelled there and opens in Peek")
    func pinnedPlainClickOpensPeek() async throws {
        let (controller, tab) = try await makeWindow()
        defer { controller.window?.close() }
        controller.peek.sourceClassifier = { _ in (.pinned, nil) }
        let loads = tab.sentRequests.count
        tab.clickLink(to: URL(string: "https://other.org/plain")!)
        await settle()
        #expect(tab.currentURL?.path == "/inbox")
        #expect(tab.sentRequests.count == loads, "nothing left the tab")
        let peeked = try #require(controller.presentedPeekSurface)
        #expect(peeked.sentRequests.map(\.method) == ["GET"])
        #expect(controller.peek.presentation?.trigger == .pinnedSourceLeavingSite)
    }

    @Test("Forms, script navigations, ⌘-clicks and disabled Shift-clicks stay in the tab with their request")
    func otherNavigationsStayInTab() async throws {
        let (controller, tab) = try await makeWindow()
        defer { controller.window?.close() }
        controller.peek.sourceClassifier = { _ in (.pinned, nil) }
        tab.submitForm(to: URL(string: "https://other.org/posted")!, modifiers: [.shift])
        await settle()
        #expect(!controller.isPeekPresented, "a POST is never cancelled and replayed")
        #expect(tab.currentURL?.path == "/posted")
        #expect(tab.sentRequests.last?.method == "POST")
        tab.scriptNavigate(to: URL(string: "https://third.net/scripted")!, modifiers: [.shift])
        await settle()
        #expect(!controller.isPeekPresented, "a script navigation is not a user link activation")
        #expect(tab.currentURL?.path == "/scripted")
        tab.clickLink(to: URL(string: "https://other.org/command")!, modifiers: [.command])
        await settle()
        #expect(!controller.isPeekPresented)
        controller.peek.settings.shiftClickOpensPeek = false
        tab.clickLink(to: URL(string: "https://www.example.com/shift-off")!, modifiers: [.shift])
        await settle()
        #expect(!controller.isPeekPresented)
        #expect(tab.currentURL?.path == "/shift-off")
        tab.openNewTarget(URL(string: "https://other.org/popup")!, modifiers: [.shift], userGesture: false)
        await settle()
        #expect(!controller.isPeekPresented, "a scripted popup never opens a Peek")
    }

    @Test("Navigations inside the Peek document are not routed again")
    func peekNavigationsStayInPeek() async throws {
        let (controller, tab) = try await makeWindow()
        defer { controller.window?.close() }
        tab.clickLink(to: URL(string: "https://other.org/one")!, modifiers: [.shift])
        await settle()
        let peeked = try #require(controller.presentedPeekSurface)
        peeked.clickLink(to: URL(string: "https://third.net/two")!, modifiers: [.shift])
        await settle()
        #expect(controller.presentedPeekSurface === peeked)
        #expect(peeked.currentURL?.path == "/two")
    }
}

}
