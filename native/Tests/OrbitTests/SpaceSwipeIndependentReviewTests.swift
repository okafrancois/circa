import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Test("Space swipe independent preview selects a split from its saved window authority and remains read only")
@MainActor
func spaceSwipeIndependentSplitSelection() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic preview authority")
    let first = try await store.createSpace(name: "Source", profileID: profile)
    let target = try await store.createSpace(name: "Destination", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: target)
    let otherWindow = try await store.createWindow(activeSpaceID: first)
    var context = try await store.captureContext(in: window)
    _ = try await store.openTab(url: URL(string: "https://synthetic.invalid/left")!, from: context, activate: true)
    context = try await store.captureContext(in: window)
    _ = try await store.openTab(url: URL(string: "https://synthetic.invalid/right")!, from: context, activate: true)
    context = try await store.captureContext(in: window)
    let ids = try await store.snapshot(of: window).tabs.map(\.id)
    _ = try await store.createSplit(ids, from: context)
    try await store.activateSpace(first, in: window)
    let before = await store.sessionDocument()
    let preview = SpaceSwipePreview.content(document: before, spaceID: target, windowID: window)
    #expect(preview.entries.count == 1)
    #expect(preview.tabs.count == 1)
    #expect(preview.tabs.first?.selected == true)
    #expect(preview.tabs.first?.occurrenceID == nil)
    let unrelated = SpaceSwipePreview.content(document: before, spaceID: target, windowID: otherWindow)
    #expect(unrelated.tabs.count == 1)
    #expect(unrelated.tabs.allSatisfy { !$0.selected && $0.occurrenceID == nil })
    #expect(await store.sessionDocument() == before)
    try await store.closeWindow(window)
    try await store.closeWindow(otherWindow)
}
}
