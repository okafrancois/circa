import BrowserCore
import Darwin
import Foundation
import Testing
@testable import Orbit

@Suite("Overlay page scrollbars setting")
struct OverlayScrollbarsSettingsTests {
    @Test("Overlay scrollbars default off, including settings saved before the option existed")
    func defaults() throws {
        #expect(!BrowserSettingsDocument().overlayScrollbars)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserSettingsDocument())) as? [String: Any])
        json.removeValue(forKey: "overlayScrollbars")
        let restored = try JSONDecoder().decode(BrowserSettingsDocument.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!restored.overlayScrollbars)
    }

    @Test("The launch snapshot follows the saved choice and falls back to classic scrollbars")
    func launchSnapshot() async throws {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("overlay-scrollbars-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("settings.json")
        #expect(!BrowserSettingsStore.overlayScrollbarsAtLaunch(destination: file))
        let store = try BrowserSettingsStore(destination: file)
        try await store.setOverlayScrollbars(true)
        #expect(BrowserSettingsStore.overlayScrollbarsAtLaunch(destination: file))
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().overlayScrollbars)
        try await reopened.setOverlayScrollbars(false)
        #expect(!BrowserSettingsStore.overlayScrollbarsAtLaunch(destination: file))
        try Data(#"{"version":999,"overlayScrollbars":true}"#.utf8).write(to: file)
        #expect(!BrowserSettingsStore.overlayScrollbarsAtLaunch(destination: file))
        try Data("not json".utf8).write(to: file)
        #expect(!BrowserSettingsStore.overlayScrollbarsAtLaunch(destination: file))
    }

    @MainActor @Test("A restart notice appears only when the choice differs from the running engine")
    func restartNotice() {
        #expect(BrowserOverlayScrollbars.state(enabled: true, atLaunch: nil) == nil)
        #expect(BrowserOverlayScrollbars.state(enabled: true, atLaunch: true) == nil)
        #expect(BrowserOverlayScrollbars.state(enabled: false, atLaunch: false) == nil)
        #expect(BrowserOverlayScrollbars.state(enabled: true, atLaunch: false) == uiText("Restart Circa to show overlay scrollbars."))
        #expect(BrowserOverlayScrollbars.state(enabled: false, atLaunch: true) == uiText("Restart Circa to restore classic scrollbars."))
    }
}
