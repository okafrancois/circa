import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

/// EXT-OUTCOME-R1: tabs an engine creates by itself (an extension's `chrome.tabs.create`, an
/// options page opened in a tab) become ordinary tabs of the window whose native browser holds
/// them, recorded after the selected tab of that profile; foreground ones are selected. Never
/// adopted into another profile, a closing window or a window that removed its handler.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct EngineTabAdoptionTests {
    private let page = URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/onboarding.html")!

    private func window() async throws -> (BrowserEnvironment<PeekSyntheticEngine>, BrowserWindowController<PeekSyntheticEngine>,
                                           PeekSyntheticEngine, PeekSyntheticSurface) {
        let engine = PeekSyntheticEngine()
        engine.capabilities.insert(.extensionDocuments)
        let environment = BrowserEnvironment(engine: engine)
        let controller = try await environment.makeWindow()
        controller.submitAddress("https://example.test/")
        await controller.session.waitForPendingCommands()
        let tab = try #require(controller.session.selectedSurface)
        return (environment, controller, engine, tab)
    }

    @Test("A foreground engine tab is recorded in the window and selected; a background one is not")
    func adoptsForegroundAndBackground() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let (_, controller, engine, tab) = try await window()
        defer { controller.window?.close() }
        let windowID = try #require(controller.session.snapshot?.id)
        #expect(engine.tabAdoption[windowID] != nil, "the window registers its handler with its engine window")

        let foreground = try #require(engine.createEngineTab(in: windowID, url: page, profileID: tab.profileID, foreground: true))
        await controller.session.waitForPendingCommands()
        #expect(controller.session.occurrenceID(for: foreground) != nil)
        #expect(controller.session.selectedSurface === foreground)
        #expect(foreground.currentURL == page && foreground.profileID == tab.profileID)

        let background = try #require(engine.createEngineTab(in: windowID, url: URL(string: "https://example.test/welcome")!,
                                                              profileID: tab.profileID, foreground: false))
        await controller.session.waitForPendingCommands()
        #expect(controller.session.occurrenceID(for: background) != nil)
        #expect(controller.session.selectedSurface === foreground, "a background engine tab never takes the selection")
    }

    @Test("A native close removes Today tabs and unloads pinned and favorite entries")
    func nativeClosePreservesSavedEntries() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let (_, controller, _, first) = try await window()
        defer { controller.window?.close() }
        let today = try #require(controller.session.organization?.selectedTab?.id)
        first.requestClose()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.occurrenceID(for: first) == nil)
        #expect(controller.session.organization?.tab(today) == nil)
        #expect(first.isDisposed)

        for favorite in [false, true] {
            controller.session.openTab(url: page)
            await controller.session.waitForPendingCommands()
            let id = try #require(controller.session.organization?.selectedTab?.id)
            if favorite { controller.session.addToFavorites([id]) }
            else { controller.session.pinTabs([id]) }
            await controller.session.waitForPendingCommands()
            let surface = try #require(controller.session.selectedSurface)
            surface.requestClose()
            await controller.session.waitForPendingCommands()
            let saved = try #require(controller.session.organization?.tab(id))
            #expect(!saved.isLoadedInThisWindow)
            #expect(controller.session.occurrenceID(for: surface) == nil)
            #expect(surface.isDisposed)
        }
    }

    @Test("Another profile, a closing window and a removed handler never adopt the tab")
    func refusesOtherProfileAndClosedWindows() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let (_, controller, engine, tab) = try await window()
        let windowID = try #require(controller.session.snapshot?.id)
        let count = engine.surfaces.count
        #expect(engine.createEngineTab(in: windowID, url: page, profileID: ProfileID(), foreground: true) == nil)
        #expect(engine.surfaces.count == count, "a refused tab gets no shell surface at all")
        #expect(controller.session.selectedSurface === tab)
        controller.window?.close()
        await controller.session.waitForPendingCommands()
        #expect(engine.createEngineTab(in: windowID, url: page, profileID: tab.profileID, foreground: true) == nil)
    }
}
}
