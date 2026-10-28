import AppKit
@testable import BrowserCore
import BrowserShell
import SwiftUI
import Testing
@testable import Orbit

/// Synthetic hidden controller/responder tests. No panel ordering, app activation or external AX.
extension NativeWebKitTests {
@Suite("Native Space symbols", .serialized)
@MainActor
struct SpaceSymbolIconTests {
    init() { NSApplication.shared.setActivationPolicy(.prohibited) }

    private func switchMode(_ picker: SpaceIconPicker, _ mode: SpaceIconPicker.Mode) {
        picker.loadViewIfNeeded()
        picker.modes.selectedSegment = mode.rawValue
        #expect(picker.modes.sendAction(picker.modes.action, to: picker.modes.target))
    }

    private func hiddenWindow(_ picker: SpaceIconPicker) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = picker.view
        return window
    }

    private func settle() async throws {
        for _ in 0..<30 { await Task.yield(); try await Task.sleep(for: .milliseconds(2)) }
    }

    @Test("Available native symbol catalog has unique typed choices and searchable localized names")
    func catalogAndSearch() {
        #expect(SpaceSymbolCatalog.items.count >= 50)
        #expect(Set(SpaceSymbolCatalog.items.map(\.choice)).count == SpaceSymbolCatalog.items.count)
        for item in SpaceSymbolCatalog.items {
            #expect(item.choice.isValid && item.emoji.isEmpty && !item.name.isEmpty)
            guard case .systemSymbol(let name) = item.choice else { Issue.record("Untyped symbol"); continue }
            #expect(SpaceIconImages.template(name, pointSize: 20) != nil)
        }
        let picker = SpaceIconPicker(currentChoice: .systemSymbol("briefcase.fill"), accent: .defaultSpace)
        picker.loadViewIfNeeded()
        #expect(picker.mode == .icons && picker.search.isEnabled)
        #expect(picker.grid.selectedItem?.choice == .systemSymbol("briefcase.fill"))
        picker.setSearch("wor")
        #expect(picker.grid.selectedItem?.choice == .systemSymbol("briefcase.fill"))
        picker.setSearch("briefcase")
        #expect(picker.visibleItems.count == 1)
        picker.setSearch("zzzzqx")
        #expect(picker.visibleItems.isEmpty)
        picker.setSearch("")
        #expect(picker.grid.selectedItem?.choice == .systemSymbol("briefcase.fill"))
    }

    @Test("Both modes traverse by physical key interpretation, Return applies the typed choice once, and Tab delegates")
    func keyboard() throws {
        for choice in [BrowserSpaceIcon.systemSymbol("globe"), .grapheme("😀")] {
            let picker = SpaceIconPicker(currentChoice: choice, accent: .defaultSpace)
            picker.loadViewIfNeeded()
            let before = picker.grid.selectedIndex
            let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "\u{F703}",
                charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
            picker.view.keyDown(with: right)
            #expect(picker.grid.selectedIndex == (before ?? 0) + 1)
            picker.handle(#selector(NSResponder.moveDown(_:)))
            picker.handle(#selector(NSResponder.moveUp(_:)))
            let selected = try #require(picker.grid.selectedItem?.choice)
            #expect(!picker.handle(#selector(NSResponder.insertTab(_:))))
            #expect(!picker.handle(#selector(NSResponder.insertBacktab(_:))))
            var chosen: [BrowserSpaceIcon] = []
            picker.onChooseIcon = { chosen.append($0) }
            picker.handle(#selector(NSResponder.insertNewline(_:)))
            picker.handle(#selector(NSResponder.insertNewline(_:)))
            picker.removeIcon(nil)
            #expect(chosen == [selected] && picker.popup.window == nil)
        }
    }

    @Test("Mode replacement revokes retained symbol and emoji AX cells, including an ABA switch")
    func staleCellsAndModeAdmission() throws {
        let picker = SpaceIconPicker(currentChoice: .systemSymbol("star.fill"), accent: .defaultSpace)
        picker.loadViewIfNeeded()
        let old = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        var choices: [BrowserSpaceIcon] = []
        picker.onChooseIcon = { choices.append($0) }
        switchMode(picker, .emoji)
        let emoji = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        #expect(!old.accessibilityPerformPress())
        switchMode(picker, .icons)
        #expect(!emoji.accessibilityPerformPress() && !old.accessibilityPerformPress())
        picker.choose(.systemSymbol("../invalid"))
        picker.choose(.systemSymbol("not.an.available.symbol"))
        picker.choose(.grapheme("🌈"))
        #expect(choices.isEmpty)
        let fresh = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        #expect(fresh.accessibilityRole() == .button && !(fresh.accessibilityLabel() ?? "").isEmpty)
        #expect(fresh.accessibilityPerformPress())
        #expect(choices.count == 1)
        #expect(!fresh.accessibilityPerformPress())
    }

    @Test("Marked composition refuses mode switch, Return, direct selection, Remove and AX then recovers")
    func composition() throws {
        let picker = SpaceIconPicker(currentChoice: .systemSymbol("star.fill"), accent: .defaultSpace)
        let window = hiddenWindow(picker)
        defer { window.close() }
        #expect(window.makeFirstResponder(picker.search))
        let editor = try #require(picker.search.currentEditor() as? NSTextView)
        let cell = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        var chosen: [BrowserSpaceIcon] = []
        picker.onChooseIcon = { chosen.append($0) }
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        switchMode(picker, .emoji)
        #expect(picker.mode == .icons && picker.modes.selectedSegment == SpaceIconPicker.Mode.icons.rawValue)
        #expect(!picker.control(picker.search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        picker.handle(#selector(NSResponder.insertNewline(_:)))
        picker.choose(.systemSymbol("star.fill")); picker.removeIcon(nil)
        #expect(!cell.accessibilityPerformPress() && chosen.isEmpty)
        editor.unmarkText()
        picker.setSearch("star")
        #expect(!cell.accessibilityPerformPress())
        picker.handle(#selector(NSResponder.insertNewline(_:)))
        #expect(chosen == [.systemSymbol("star.fill")] && !window.isVisible)
    }

    @Test("Mouse-up from an earlier grid generation cannot apply the new mode or query")
    func staleClick() throws {
        let picker = SpaceIconPicker(currentChoice: .systemSymbol("globe"), accent: .defaultSpace)
        let window = hiddenWindow(picker)
        defer { window.close() }
        var chosen: [BrowserSpaceIcon] = []
        picker.onChooseIcon = { chosen.append($0) }
        let cell = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        let rect = cell.accessibilityFrameInParentSpace()
        let point = picker.grid.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        picker.grid.mouseDown(with: try event(.leftMouseDown))
        switchMode(picker, .emoji)
        switchMode(picker, .icons)
        picker.grid.mouseUp(with: try event(.leftMouseUp))
        #expect(chosen.isEmpty)
        picker.grid.mouseDown(with: try event(.leftMouseDown))
        picker.grid.mouseUp(with: try event(.leftMouseUp))
        #expect(chosen == [.systemSymbol("globe")] && !window.isVisible)
    }

    @Test("Remove clears symbols once and Escape clears icon search before cancelling without a commit")
    func removeAndCancel() {
        var choices: [BrowserSpaceIcon] = []
        let picker = SpaceIconPicker(currentChoice: .systemSymbol("star.fill"), accent: .defaultSpace)
        picker.onChooseIcon = { choices.append($0) }
        picker.loadViewIfNeeded()
        #expect(picker.removeButton.isEnabled)
        picker.removeIcon(nil); picker.removeIcon(nil)
        #expect(choices == [.none])
        let cancelled = SpaceIconPicker(currentChoice: .systemSymbol("star.fill"), accent: .defaultSpace)
        cancelled.onChooseIcon = { choices.append($0) }
        cancelled.setSearch("star")
        cancelled.handle(#selector(NSResponder.cancelOperation(_:)))
        #expect(cancelled.search.stringValue.isEmpty)
        cancelled.handle(#selector(NSResponder.cancelOperation(_:)))
        cancelled.choose(.systemSymbol("star.fill"))
        #expect(choices == [.none] && cancelled.popup.window == nil)
    }

    @Test("The real controller commits symbols durably and projects the identical choice into footer, Library and Settings")
    func controllerProjection() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("orbit-symbol-controller-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        environment.settings = BrowserSettingsRuntime(store: try BrowserSettingsStore(destination: file))
        environment.settings.onChange = { [weak environment] in environment?.settingsDidChange() }
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let id = try #require(controller.session.snapshot?.activeSpaceID)
        let picker = try #require(controller.makeSpaceIconPicker(for: id))
        switchMode(picker, .icons)
        picker.setSearch("briefcase")
        picker.handle(#selector(NSResponder.insertNewline(_:)))
        try await settle()
        let choice = BrowserSpaceIcon.systemSymbol("briefcase.fill")
        #expect(environment.settings.document.space(id).iconSelection == choice)
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().space(id).iconSelection == choice)
        let button = try #require(controller.sidebar.footer.spaceButtons.first { $0.space.id == id })
        #expect(button.iconSelection == choice && button.settingsIcon.isEmpty)
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let library = controller.library.spacesView
        let index = try #require(library.rows.firstIndex { $0.space.id == id })
        #expect(library.rows[index].iconSelection == choice && library.rows[index].icon == nil)
        let libraryImage = try #require(library.tiles[index].iconView as? NSImageView)
        let settingsImage = try #require(BrowserSettingsIconPreview.projection(choice) as? NSImageView)
        #expect(libraryImage.image === settingsImage.image && libraryImage.image?.isTemplate == true)
        #expect(settingsImage.accessibilityLabel() == uiText("Work"))
        let next = try #require(controller.makeSpaceIconPicker(for: id))
        next.loadViewIfNeeded()
        #expect(next.mode == .icons && next.grid.selectedItem?.choice == choice)
        // Both legacy write surfaces must replace or clear a symbol.
        let editor = try #require(controller.makeSpaceIconEditor(for: id))
        editor.field.stringValue = "👩🏽‍💻"; editor.complete(.alertFirstButtonReturn)
        await editor.waitForSave()
        #expect(button.iconSelection == .grapheme("👩🏽‍💻"))
        #expect(controller.library.spacesView.rows.first { $0.space.id == id }?.iconSelection == .grapheme("👩🏽‍💻"))
        let symbolAgain = try #require(controller.makeSpaceIconPicker(for: id))
        switchMode(symbolAgain, .icons); symbolAgain.choose(choice)
        try await settle()
        let model = BrowserSettingsModel(environment: environment, profileID: controller.session.activeProfileID, shortcuts: [])
        await model.reload()
        let profile = try #require(controller.session.activeProfileID)
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled], backing: .buffered, defer: true)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentViewController = NSHostingController(rootView:
            BrowserSettingsView(model: model, runtime: model.runtime, initialSection: .spaces))
        defer { settingsWindow.close() }
        func settingsPreview() -> NSImageView? {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            guard let root = settingsWindow.contentView else { return nil }
            root.layoutSubtreeIfNeeded()
            func find(_ view: NSView) -> NSImageView? {
                if view.accessibilityIdentifier() == "settings-space-icon-preview" { return view.subviews.first as? NSImageView }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(root)
        }
        try await withNativeTestDeadline("Settings renders the stored native Space symbol", timeout: 3) {
            while settingsPreview()?.accessibilityLabel() != uiText("Work") { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(settingsPreview()?.image === libraryImage.image && !settingsWindow.isVisible)
        let draft = BrowserSettingsIconDraft(choice: choice)
        draft.text = "🇫🇷"
        draft.submit { value in model.queueSpaceIconEdit(spaceID: id, profileID: profile, icon: BrowserSpaceIcon(legacyIcon: value)) }
        await model.waitForPendingActions()
        #expect(button.iconSelection == .grapheme("🇫🇷"))
        try await withNativeTestDeadline("Settings replaces the symbol preview with its emoji", timeout: 3) {
            while settingsPreview()?.accessibilityLabel() != "🇫🇷" { try await Task.sleep(for: .milliseconds(10)) }
        }
        let finalSymbol = try #require(controller.makeSpaceIconPicker(for: id))
        switchMode(finalSymbol, .icons); finalSymbol.choose(choice)
        try await settle()
        let clear = try #require(controller.makeSpaceIconEditor(for: id))
        #expect(clear.alert.buttons[2].isEnabled)
        clear.complete(.alertThirdButtonReturn); await clear.waitForSave()
        #expect(button.iconSelection == .none && environment.settings.document.space(id).iconSelection == .none)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Archiving and restoring an unrelated Space retains typed settings and exact profile ownership")
    func archiveRestoration() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let id = try #require(controller.session.snapshot?.activeSpaceID)
        let profile = try #require(controller.session.activeProfileID)
        let otherProfile = await environment.store.createProfile(name: "Synthetic archive profile")
        let other = try await environment.store.createSpace(name: "Synthetic archive Space", profileID: otherProfile)
        try await environment.settings.updateSpace(id) { $0.iconSelection = .systemSymbol("star.fill"); $0.palette = .lavender }
        let before = environment.settings.document.space(id)
        try await environment.removeSpaceFromSettings(other, expectedProfileID: otherProfile)
        try await environment.store.restoreSettingsSpace(other, expectedProfileID: otherProfile)
        let catalog = await environment.store.catalogSnapshot()
        #expect(catalog.spaces.contains { $0.id == other && $0.profileID == otherProfile })
        #expect(catalog.spaces.contains { $0.id == id && $0.profileID == profile })
        #expect(environment.settings.document.space(id) == before)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Controller and Settings reject stale captured Space/profile targets without changing another Space")
    func targetAuthority() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let first = try #require(controller.session.snapshot?.activeSpaceID)
        let profile = try #require(controller.session.activeProfileID)
        let otherProfile = await environment.store.createProfile(name: "Synthetic second")
        let other = try await environment.store.createSpace(name: "Synthetic other", profileID: otherProfile)
        let inactive = try await environment.store.createSpace(name: "Synthetic inactive", profileID: profile)
        await environment.refreshSettingsCatalog()
        let reprofiled = try #require(controller.makeSpaceIconPicker(for: inactive))
        switchMode(reprofiled, .icons)
        try await environment.store.assignSettingsSpace(inactive, to: otherProfile)
        reprofiled.choose(.systemSymbol("star.fill"))
        try await settle()
        #expect(environment.settings.document.space(inactive).iconSelection == .none)
        let stale = try #require(controller.makeSpaceIconPicker(for: first))
        switchMode(stale, .icons)
        controller.session.activateSpace(other)
        stale.choose(.systemSymbol("star.fill"))
        await controller.session.waitForPendingCommands(); try await settle()
        #expect(environment.settings.document.space(first).iconSelection == .none)
        #expect(environment.settings.document.space(other).iconSelection == .none)
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        model.queueSpaceIconEdit(spaceID: first, profileID: profile, icon: .systemSymbol("star.fill"))
        model.selectProfile(otherProfile)
        await model.waitForPendingActions()
        #expect(environment.settings.document.space(first).iconSelection == .none)
        model.queueSpaceIconEdit(spaceID: first, profileID: otherProfile, icon: .systemSymbol("star.fill"))
        await model.waitForPendingActions()
        #expect(environment.settings.document.space(first).iconSelection == .none)
        await environment.refreshSettingsCatalog()
        let removed = try #require(controller.makeSpaceIconPicker(for: inactive))
        switchMode(removed, .icons)
        try await environment.removeSpaceFromSettings(inactive)
        removed.choose(.systemSymbol("star.fill")); try await settle()
        #expect(environment.settings.document.space(inactive).iconSelection == .none)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Native template tint and inactive monochrome reuse caches; dense geometry still draws only a dot")
    func renderAndCache() throws {
        let space = BrowserSpace(id: SpaceID(), profileID: ProfileID(), name: "Synthetic")
        let active = SidebarSpaceButton(space: space, index: 0, isActive: true)
        let inactive = SidebarSpaceButton(space: space, index: 0, isActive: false)
        for button in [active, inactive] {
            button.iconSelection = .systemSymbol("star.fill")
            button.tint = NSColor(srgbRed: 0.8, green: 0.2, blue: 0.3, alpha: 1)
        }
        let one = try #require(SpaceIconImages.symbol("star.fill", pointSize: 15, tint: active.tint, active: true, appearance: active.effectiveAppearance))
        #expect(one === SpaceIconImages.symbol("star.fill", pointSize: 15, tint: active.tint, active: true, appearance: active.effectiveAppearance))
        func pixels(_ button: SidebarSpaceButton) -> (visible: Int, colored: Int) {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            button.customDrawing?(button, NSRect(x: 0, y: 0, width: 40, height: 40))
            NSGraphicsContext.restoreGraphicsState()
            var visible = 0, colored = 0
            for y in 0..<40 { for x in 0..<40 {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.1 else { continue }
                visible += 1
                if abs(c.redComponent - c.blueComponent) > 0.1 { colored += 1 }
            } }
            return (visible, colored)
        }
        #expect(pixels(active).colored > 0)
        #expect(pixels(inactive).visible > 0 && pixels(inactive).colored == 0)
        let footer = SidebarFooterView()
        footer.render(spaces: [space], activeSpaceID: space.id)
        let themed = try #require(footer.spaceButtons.first)
        themed.iconSelection = .systemSymbol("star.fill")
        let previous = themed.tint.resolved(for: NSAppearance(named: .aqua)!)
        footer.accent = .derived(hue: 0.03)
        #expect(themed.tint.resolved(for: NSAppearance(named: .aqua)!) != previous)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            themed.appearance = NSAppearance(named: appearance)
            #expect(pixels(themed).visible > 0)
        }
        active.presentation = .dots
        let dense = pixels(active)
        #expect(dense.visible > 0 && dense.visible < 70)
        active.settingsIcon = "🌈"
        #expect(active.iconSelection == .grapheme("🌈"))
        active.presentation = .icons
        #expect(pixels(active).visible > dense.visible)
    }
}
}
