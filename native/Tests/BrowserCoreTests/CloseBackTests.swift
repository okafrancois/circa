import Foundation
import Testing
@testable import BrowserCore

@Suite struct CloseBackTests {
    @Test("Close uses real selection order even when timestamps tie", arguments: [false, true])
    func mru(archive: Bool) async throws {
        let store = BrowserStore(clock: { Date(timeIntervalSince1970: 1) })
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Home", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        var tabs: [TabOccurrenceID] = []
        for i in 1...5 {
            tabs.append(try await store.openTab(url: URL(string: "https://example.test/t\(i)")!, from: store.captureContext(in: window), activate: true))
        }
        for i in [1,4,2] { try await store.selectOccurrence(tabs[i], in: window) }
        if archive {
            let id = try #require(try await store.snapshot(of: window).tabs.first { $0.occurrenceID == tabs[2] }?.id)
            _ = try await store.archiveTabs([id], from: store.captureContext(in: window))
        } else { try await store.closeOccurrence(tabs[2], from: store.captureContext(in: window)) }
        #expect(try await store.snapshot(of: window).selectedOccurrenceID == tabs[4])
    }

    @Test("Background child closes to MRU; foreground child closes to the previous selection", arguments: [false, true])
    func childClose(foreground: Bool) async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Home", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let parent = try await store.openTab(url: URL(string: "https://example.test/parent")!, from: store.captureContext(in: window), activate: true)
        let other = try await store.openTab(url: URL(string: "https://example.test/other")!, from: store.captureContext(in: window), activate: false)
        let parentID = try #require(try await store.snapshot(of: window).tabs.first?.id)
        let child = try await store.openTab(url: URL(string: "https://example.test/child")!, from: store.captureContext(in: window), activate: foreground, nextTo: parentID)
        let order = try await store.organizationSnapshot(for: window).allTabs.map(\.id)
        let childID = try #require(try await store.snapshot(of: window).tabs.first { $0.occurrenceID == child }?.id)
        #expect(order.firstIndex(of: childID) == order.firstIndex(of: parentID)! + 1)
        if !foreground {
            try await store.selectOccurrence(other, in: window)
            try await store.selectOccurrence(child, in: window)
        }
        try await store.closeOccurrence(child, from: store.captureContext(in: window))
        #expect(try await store.snapshot(of: window).selectedOccurrenceID == (foreground ? parent : other))
    }

    @Test("Closing a pin or last folder tab unloads it; removal and undo preserve identity", arguments: [false, true])
    func pinned(inFolder: Bool) async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Home", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let other = try await store.openTab(url: URL(string: "https://example.test/other")!, from: store.captureContext(in: window), activate: true)
        let pin = try await store.openTab(url: URL(string: "https://example.test/pin")!, from: store.captureContext(in: window), activate: true)
        let id = try #require(try await store.snapshot(of: window).tabs.last?.id)
        _ = try await store.pinTabs([id], from: store.captureContext(in: window))
        if inFolder {
            _ = try await store.createFolder(title: "Folder", at: .init(.pinned(space)), containing: [.tab(id)], from: store.captureContext(in: window))
        }
        try await store.closeOccurrence(pin, from: store.captureContext(in: window))
        #expect(try await store.snapshot(of: window).selectedOccurrenceID == other)
        #expect(try await store.organizationSnapshot(for: window).tab(id) != nil)
        _ = try await store.archiveTabs([id], from: store.captureContext(in: window))
        #expect(try await store.organizationSnapshot(for: window).tab(id) == nil)
        _ = try await store.undoOrganization(from: store.captureContext(in: window))
        #expect(try await store.organizationSnapshot(for: window).tab(id) != nil)
    }
}
