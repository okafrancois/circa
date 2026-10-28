import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Independent daily UI review", .serialized)
@MainActor
struct ReviewDailyUITests {
    @Test("An icon draft reads the latest Space fields on acceptance and never restores its opening form")
    func reviewIconDraftPreservesLaterSettings() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let id = try #require(controller.session.snapshot?.activeSpaceID)
        let editor = try #require(controller.makeSpaceIconEditor(for: id))
        try await environment.settings.updateSpace(id) { $0.palette = .rosePlum }
        editor.field.stringValue = "👨‍👩‍👧‍👦"
        editor.complete(.alertFirstButtonReturn)
        await editor.waitForSave()
        let saved = await environment.settings.store.snapshot().space(id)
        #expect(saved.icon == "👨‍👩‍👧‍👦")
        #expect(saved.palette == .rosePlum)
        let retired = try #require(controller.makeSpaceIconEditor(for: id))
        controller.session.close()
        retired.field.stringValue = "🧪"
        retired.complete(.alertFirstButtonReturn)
        await retired.waitForSave()
        #expect(await environment.settings.store.snapshot().space(id) == saved)
    }

    @Test("Creation menu accessibility presses skip disabled services and dispatch only the selected action")
    func reviewCreationAccessibility() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var calls: [BrowserCommandID] = []
        let actions = [BrowserCommandID.newTab, .manageExtensions, .addExtension].map { id in
            SidebarCreationAction(command: id, title: id.rawValue, symbol: "plus", shortcut: "", enabled: id != .manageExtensions) { calls.append(id) }
        }
        var menu: SidebarCreationMenu? = SidebarCreationMenu(actions: actions, accent: .defaultSpace)
        weak var released = menu
        let rows = try #require(menu).view.subviews.filter { $0.accessibilityRole() == .menuItem }
        #expect(rows.count == 3)
        #expect(!rows[1].accessibilityPerformPress())
        #expect(calls.isEmpty)
        #expect(rows[2].accessibilityPerformPress())
        #expect(calls == [.addExtension])
        menu = nil
        #expect(released == nil)
    }

    @Test("Reusing a compact row recomputes detail width when the result changes")
    func reviewReusedCompactRowLayout() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = BrowserPaletteView(frame: try #require(window.contentView).bounds)
        window.contentView?.addSubview(view)
        func result(_ detail: String) -> BrowserPaletteResult {
            // command-bar-2026-10-27.md: details are inline page metadata, not command accessories.
            .init(id: "synthetic", title: "Synthetic title", detail: detail, section: .history,
                  action: .navigate(URL(string: "https://palette.test/")!))
        }
        view.render([result("x")], selected: 0)
        view.layoutSubtreeIfNeeded()
        let table = try #require(view.scroll.documentView as? NSTableView)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? PaletteResultCell)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.detailLabel.stringValue == "x")
        view.render([result("Chrome Web Store: synthetic longer detail")], selected: 0)
        view.layoutSubtreeIfNeeded()
        cell.layoutSubtreeIfNeeded()
        #expect((table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? PaletteResultCell) === cell)
        #expect(cell.detailLabel.stringValue == "Chrome Web Store: synthetic longer detail")
        let text = (cell.detailLabel.stringValue as NSString).size(withAttributes: [.font: cell.detailLabel.font!]).width
        #expect(cell.detailLabel.frame.width >= ceil(text) + 2)
        #expect(cell.titleLabel.frame.maxX < cell.detailLabel.frame.minX)
    }

    @Test("Concurrent independent Space field mutations retain both edits")
    func reviewConcurrentSpaceFieldMutations() async throws {
        let runtime = BrowserSettingsRuntime(store: try BrowserSettingsStore())
        let id = SpaceID()
        let palette = Task { try await runtime.updateSpace(id) { $0.palette = .lavender } }
        let icon = Task { try await runtime.updateSpace(id) { $0.icon = "🧪" } }
        try await palette.value
        try await icon.value
        let value = await runtime.store.snapshot().space(id)
        #expect(value.palette == .lavender)
        #expect(value.icon == "🧪")
    }
}
}
