import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Browser window content privacy", .serialized)
@MainActor
struct WindowContentPrivacyTests {
    private func window(private isPrivate: Bool) async throws -> BrowserWindowController<PeekSyntheticEngine> {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic privacy")
        let space = try await store.createSpace(name: "Space", profileID: profile)
        let owner = BrowserWindowController(id: UUID(), store: store, spaceID: space, engine: PeekSyntheticEngine(),
                                            isPrivateWindow: isPrivate, onClose: {}, onActivate: {})
        await owner.session.waitForPendingCommands()
        return owner
    }

    @Test("Browser windows are never handed to macOS window restoration")
    func notRestorable() async throws {
        for isPrivate in [false, true] {
            let owner = try await window(private: isPrivate)
            defer { owner.session.close(); owner.window?.close() }
            #expect(owner.window?.isRestorable == false)
        }
    }

    @Test("Private windows and their panels stay out of other applications' captures; normal windows do not")
    func privateWindowsAreNotShared() async throws {
        let normal = try await window(private: false)
        defer { normal.session.close(); normal.window?.close() }
        #expect(normal.window?.sharingType == .readOnly)
        let owner = try await window(private: true)
        defer { owner.session.close(); owner.window?.close() }
        let window = try #require(owner.window)
        #expect(window.sharingType == NSWindow.SharingType.none)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(panel.sharingType == .readOnly)
        window.addChildWindow(panel, ordered: .above)
        defer { window.removeChildWindow(panel); panel.close() }
        #expect(panel.sharingType == NSWindow.SharingType.none)
        let normalPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        try #require(normal.window).addChildWindow(normalPanel, ordered: .above)
        defer { normal.window?.removeChildWindow(normalPanel); normalPanel.close() }
        #expect(normalPanel.sharingType == .readOnly)
    }
}
}
