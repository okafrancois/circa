import AppKit
import BrowserCore
import Foundation
import Darwin
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Tab hover preview preference", .serialized)
@MainActor
struct TabHoverPreviewSettingsTests {
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    @Test("Hover previews default off and only an explicit saved opt-in survives a restart")
    func defaultsAndPersistence() async throws {
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("hover-setting-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let store = try BrowserSettingsStore(destination: file)
        #expect(await store.snapshot().showsTabHoverPreviews == false)
        try await store.setShowsTabHoverPreviews(true)
        #expect(try await BrowserSettingsStore(destination: file).snapshot().showsTabHoverPreviews)
        try await store.setShowsTabHoverPreviews(false)
        #expect(try await BrowserSettingsStore(destination: file).snapshot().showsTabHoverPreviews == false)
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for value in [nil, "invalid"] as [String?] {
            legacy["showsTabHoverPreviews"] = value
            let bytes = try JSONSerialization.data(withJSONObject: legacy)
            try bytes.write(to: file)
            #expect(try await BrowserSettingsStore(destination: file).snapshot().showsTabHoverPreviews == false)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test("All live windows gate content and extra snapshot resolution on the same opt-in")
    func liveWindows() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let first = try await environment.makeWindow()
        let second = try await environment.makeWindow()
        defer { first.window?.close(); second.window?.close() }
        for owner in [first, second] {
            owner.session.openTab(url: URL(string: "https://example.test/preview")!)
            await owner.session.waitForQueuedCommands()
        }
        func check(_ enabled: Bool) throws {
            for owner in [first, second] {
                let surface = try #require(owner.session.selectedSurface)
                let tab = try #require(owner.session.organization?.selectedTab?.id)
                #expect((owner.richTabContent(tab) != nil) == enabled)
                #expect(owner.tabSwitcher.snapshots.captureWidth(surface) == (enabled ? 240 : 200))
                #expect(owner.folderPreview.snapshots.captureWidth(surface) == (enabled ? 240 : 200))
            }
        }
        try check(false)
        try await environment.settings.setShowsTabHoverPreviews(true)
        try check(true)
        try await environment.settings.setShowsTabHoverPreviews(false)
        try check(false)
        #expect(first.richTabPreview.view.superview == nil && second.richTabPreview.view.superview == nil)
    }
}
}
