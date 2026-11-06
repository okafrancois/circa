import AppKit
@testable import BrowserCore
import BrowserShell
import Darwin
import Foundation
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Space icon dots preference", .serialized)
@MainActor
struct SpaceIconDotsSettingsTests {
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    @Test("Dots default off, persist across reopen and never rewrite stored Space icons")
    func defaultsAndPersistence() async throws {
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("space-dots-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let emoji = SpaceID(), symbol = SpaceID()
        let store = try BrowserSettingsStore(destination: file)
        #expect(await store.snapshot().usesDotsForSpaceIcons == false)
        try await store.updateSpace(emoji) { $0.iconSelection = .grapheme("🧪") }
        try await store.updateSpace(symbol) { $0.iconSelection = .systemSymbol("star.fill") }
        let spaces = await store.snapshot().spaces
        try await store.setUsesDotsForSpaceIcons(true)
        let enabled = try BrowserSettingsStore(destination: file)
        #expect(await enabled.snapshot().usesDotsForSpaceIcons)
        #expect(await enabled.snapshot().spaces == spaces)
        #expect(await enabled.snapshot().displayedSpaceIcon(emoji) == .none)
        try await enabled.setUsesDotsForSpaceIcons(false)
        let restored = try BrowserSettingsStore(destination: file)
        #expect(await restored.snapshot().displayedSpaceIcon(emoji) == .grapheme("🧪"))
        #expect(await restored.snapshot().displayedSpaceIcon(symbol) == .systemSymbol("star.fill"))
        // A file written before the preference existed loads as off and is not rewritten.
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy.removeValue(forKey: "usesDotsForSpaceIcons")
        let bytes = try JSONSerialization.data(withJSONObject: legacy)
        try bytes.write(to: file)
        let migrated = try BrowserSettingsStore(destination: file)
        #expect(await migrated.snapshot().usesDotsForSpaceIcons == false)
        #expect(await migrated.snapshot().spaces == spaces)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("Live windows switch header and switcher to dots, keep edits made meanwhile and restore icons")
    func liveWindows() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let first = try await environment.makeWindow()
        let firstSpace = try #require(first.session.snapshot?.activeSpaceID)
        let profile = try #require(first.session.activeProfileID)
        let other = try await environment.store.createSpace(name: "Synthetic dots Space", profileID: profile)
        let second = try await environment.makeWindow(spaceID: other)
        defer { environment.autoArchive.scheduler.stop(); first.window?.close(); second.window?.close() }
        await first.session.waitForPendingCommands(); await second.session.waitForPendingCommands()
        try await environment.settings.updateSpace(firstSpace) { $0.iconSelection = .grapheme("🏀") }
        try await environment.settings.updateSpace(other) { $0.iconSelection = .systemSymbol("heart.fill") }
        let expected: [SpaceID: BrowserSpaceIcon] = [firstSpace: .grapheme("🏀"), other: .systemSymbol("heart.fill")]
        func displayed(_ controller: BrowserWindowController<SiteSyntheticEngine>, _ id: SpaceID) -> BrowserSpaceIcon? {
            controller.sidebar.footer.spaceButtons.first { $0.space.id == id }?.iconSelection
        }
        for controller in [first, second] {
            for (id, icon) in expected { #expect(displayed(controller, id) == icon) }
        }
        #expect(first.sidebar.page.iconSelection == .grapheme("🏀") && !first.sidebar.page.iconButton.isHidden)

        try await environment.settings.setUsesDotsForSpaceIcons(true)
        for controller in [first, second] {
            for id in expected.keys { #expect(displayed(controller, id) == BrowserSpaceIcon.none) }
            #expect(controller.sidebar.page.iconSelection == .none && controller.sidebar.page.iconButton.isHidden)
            #expect(controller.sidebar.resolveSpaceIcon(firstSpace) == .none)
            // Names, selection state and shortcuts stay on the accessible buttons.
            let names = controller.sidebar.footer.spaceButtons.map { $0.accessibilityLabel() ?? "" }
            #expect(names.contains(OrbitShellText.space("Synthetic dots Space")))
            #expect(controller.sidebar.footer.spaceButtons.filter { $0.isActive }.count == 1)
        }
        for (id, icon) in expected { #expect(environment.settings.document.space(id).iconSelection == icon) }

        // Choosing an icon while dots are shown stores it without displaying it.
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        model.queueSpaceIconEdit(spaceID: other, profileID: profile, icon: .grapheme("🎯"))
        await model.waitForPendingActions()
        #expect(environment.settings.document.space(other).iconSelection == .grapheme("🎯"))
        #expect(displayed(first, other) == BrowserSpaceIcon.none && displayed(second, other) == BrowserSpaceIcon.none)

        try await environment.settings.setUsesDotsForSpaceIcons(false)
        for controller in [first, second] {
            #expect(displayed(controller, firstSpace) == .grapheme("🏀"))
            #expect(displayed(controller, other) == .grapheme("🎯"))
            #expect(controller.window?.isVisible == false)
        }
        #expect(first.sidebar.page.iconSelection == .grapheme("🏀") && !first.sidebar.page.iconButton.isHidden)
        #expect(second.sidebar.page.iconSelection == .grapheme("🎯"))
    }

    @Test("A dotted switcher button draws the same dot as a Space without an icon")
    func switcherRender() throws {
        func render(_ icon: BrowserSpaceIcon, active: Bool) throws -> Data {
            let space = BrowserSpace(id: SpaceID(), profileID: ProfileID(), name: "Synthetic render Space")
            let button = SidebarSpaceButton(space: space, index: 0, isActive: active)
            button.appearance = NSAppearance(named: .aqua)
            button.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
            button.tint = NSColor.labelColor
            button.iconSelection = icon
            let rep = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: rep)
            return try #require(rep.tiffRepresentation)
        }
        let id = SpaceID()
        var document = BrowserSettingsDocument()
        document.spaces[id] = { var value = BrowserSpaceSettings(); value.iconSelection = .grapheme("🏀"); return value }()
        for active in [true, false] {
            let dot = try render(.none, active: active)
            document.usesDotsForSpaceIcons = false
            #expect(try render(document.displayedSpaceIcon(id), active: active) != dot)
            document.usesDotsForSpaceIcons = true
            #expect(try render(document.displayedSpaceIcon(id), active: active) == dot)
        }
        #expect(try render(.none, active: true) != render(.none, active: false))
    }
}
}
