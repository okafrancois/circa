import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

/// Hidden source tests: no visible window, activation, personal root or real settings.
extension NativeWebKitTests {
@Suite("Space icon picker", .serialized)
@MainActor
struct SpaceIconPickerTests {
    @Test("The catalog lists valid single-grapheme emoji in every category, flags as pairs, no bare components")
    func catalog() {
        let catalog = SpaceIconPickerCatalog.shared
        #expect(catalog.items.count > 1000)
        for category in SpaceIconPickerCatalog.Category.allCases {
            #expect(!catalog.items(in: category).isEmpty, "empty \(category)")
        }
        #expect(catalog.items.allSatisfy { BrowserSpaceSettings.isValidIcon($0.emoji) && $0.emoji.count == 1 })
        #expect(Set(catalog.items.map(\.emoji)).count == catalog.items.count)
        #expect(catalog.items.contains { $0.emoji == "😀" && $0.category == .smileys })
        #expect(catalog.items.contains { $0.emoji == "🇫🇷" && $0.category == .flags })
        #expect(catalog.items.contains { $0.emoji == "☀️" })
        #expect(!catalog.items.contains { ["🏽", "🇫", "🦰"].contains($0.emoji) })
        let categories = catalog.items.map(\.category.rawValue)
        #expect(categories == categories.sorted())
    }

    @Test("Search matches word prefixes of English names; a typed emoji is offered first")
    func search() {
        let catalog = SpaceIconPickerCatalog.shared
        #expect(catalog.search("grinning").contains { $0.emoji == "😀" })
        #expect(catalog.search("heavy black hea").contains { $0.emoji == "❤️" })
        #expect(catalog.search("france").contains { $0.emoji == "🇫🇷" })
        #expect(catalog.search("zzzzqx").isEmpty)
        #expect(SpaceIconPickerCatalog.typedEmoji(" 👩🏽‍💻 ") == "👩🏽‍💻")
        #expect(SpaceIconPickerCatalog.typedEmoji("a") == nil && SpaceIconPickerCatalog.typedEmoji("1") == nil)
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        picker.setSearch("👩🏽‍💻")
        #expect(picker.visibleItems.first?.emoji == "👩🏽‍💻")
        #expect(picker.grid.selectedItem?.emoji == "👩🏽‍💻")
        picker.setSearch("")
        #expect(picker.visibleItems.count == SpaceIconPickerCatalog.shared.items.count)
    }

    @Test("Choosing applies once, Remove is only offered with an icon, Escape clears the query then closes without a choice")
    func choiceLifecycle() {
        var chosen: [String] = []
        let picker = SpaceIconPicker(currentIcon: "🌈", accent: .defaultSpace)
        picker.onChoose = { chosen.append($0) }
        picker.loadViewIfNeeded()
        #expect(picker.removeButton.isEnabled)
        #expect(picker.grid.selectedItem?.emoji == "🌈")
        picker.handle(#selector(NSResponder.moveDown(_:)))
        #expect(picker.grid.selectedItem?.emoji != "🌈")
        picker.handle(#selector(NSResponder.insertNewline(_:)))
        picker.removeIcon(nil)
        picker.choose("🎉")
        #expect(chosen.count == 1 && chosen.first != "🌈")

        var removed: [String] = []
        let withIcon = SpaceIconPicker(currentIcon: "🌈", accent: .defaultSpace)
        withIcon.onChoose = { removed.append($0) }
        withIcon.removeIcon(nil)
        #expect(removed == [""])

        var none: [String] = []
        let empty = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        empty.onChoose = { none.append($0) }
        empty.loadViewIfNeeded()
        #expect(!empty.removeButton.isEnabled)
        empty.removeIcon(nil)
        empty.setSearch("cat")
        empty.handle(#selector(NSResponder.cancelOperation(_:)))
        #expect(empty.search.stringValue.isEmpty)
        empty.handle(#selector(NSResponder.cancelOperation(_:)))
        empty.choose("🐱")
        #expect(none.isEmpty)
    }

    @Test("Every grid cell is an accessibility button whose press chooses that emoji")
    func accessibility() throws {
        var chosen: [String] = []
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        picker.onChoose = { chosen.append($0) }
        picker.setSearch("grinning")
        let elements = try #require(picker.grid.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(elements.count == picker.visibleItems.count && !elements.isEmpty)
        #expect(elements.allSatisfy { $0.accessibilityRole() == .button && !($0.accessibilityLabel() ?? "").isEmpty })
        #expect(elements[0].accessibilityPerformPress())
        #expect(chosen == [picker.visibleItems[0].emoji])
    }

    @Test("The footer context-menu action presents the picker for its Space and the choice commits through settings")
    func footerPresentation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-icon-picker-synthetic-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        environment.settings = BrowserSettingsRuntime(store: try BrowserSettingsStore(destination: directory.appendingPathComponent("settings.json")))
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        let picker = try #require(controller.makeSpaceIconPicker(for: space))
        picker.choose("🦊")
        for _ in 0..<50 where environment.settings.document.space(space).icon != "🦊" { await Task.yield(); try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(environment.settings.document.space(space).icon == "🦊")
        // A hidden footer cannot host the panel (the sheet fallback is not presented by this test).
        #expect(!controller.sidebar.footer.presentIconPicker(try #require(controller.makeSpaceIconPicker(for: space)), for: space))
        #expect(controller.sidebar.footer.iconPicker == nil)
        #expect(controller.window?.isVisible == false)
    }
}
}
