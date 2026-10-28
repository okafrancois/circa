import Foundation
import Testing
@testable import BrowserCore

@Test("Window placement survives session encoding without revoking document contexts")
func windowPlacementRoundTrip() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    let context = try await store.captureContext(in: window)
    let placement = BrowserWindowPlacement(x: 70, y: 80, width: 850, height: 610, sidebarWidth: 280)
    await store.updateWindowPlacements([window: placement, WindowID(): placement])
    #expect(await store.isCurrent(context))
    let document = try await BrowserSessionDocument.decode(store.sessionDocument().encoded())
    let restored = try BrowserStore(restoring: document)
    #expect(await restored.sessionDocument().windows.first?.placement == placement)
    #expect(document.windows.count == 1)

    let invalid = BrowserWindowPlacement(x: .infinity, y: 0, width: 850, height: 610, sidebarWidth: 280)
    await store.updateWindowPlacements([window: invalid])
    #expect(await store.sessionDocument().windows.first?.placement == placement)
}

@Test("Existing session windows without native placement remain decodable")
func windowPlacementIsOptional() async throws {
    let window = BrowserSessionDocument.Window(id: WindowID(), activeSpaceID: SpaceID(), spaces: [])
    let data = try JSONEncoder().encode(window)
    let decoded = try JSONDecoder().decode(BrowserSessionDocument.Window.self, from: data)
    #expect(decoded.placement == nil)
    #expect(!String(decoding: data, as: UTF8.self).contains("placement"))
}
