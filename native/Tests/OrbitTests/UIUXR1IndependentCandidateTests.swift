import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

/// Adverse witnesses deliberately remain ordinary failing assertions when candidate behavior is wrong.
/// No windows or panels are ordered, activated, or presented by these tests.
extension NativeWebKitTests {
@Suite("UI R1 independent candidate boundaries", .serialized)
@MainActor
struct UIUXR1IndependentCandidateTests {
    @Test("Dense footer dots stay inside their own hit widths")
    func denseDotContainmentAdverse() {
        for (width, count): (CGFloat, Int) in [(180, 40), (228, 60), (400, 200)] {
            let layout = FooterSpaceLayout.resolve(count: count, libraryCenterX: 24, plusCenterX: width - 24)
            #expect(layout.dotDiameter <= layout.pitch, "width \(width), count \(count)")
        }
    }

    @Test("Icons placeholder mode cannot apply an invisible emoji via Return")
    func iconsModeKeyboardAdverse() {
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        var chosen: [String] = []
        picker.onChoose = { chosen.append($0) }
        picker.loadViewIfNeeded()
        picker.modes.selectedSegment = SpaceIconPicker.Mode.icons.rawValue
        _ = picker.modes.sendAction(picker.modes.action, to: picker.modes.target)
        #expect(picker.mode == .icons)
        picker.handle(#selector(NSResponder.insertNewline(_:)))
        #expect(chosen.isEmpty)
    }

    @Test("Retained accessibility cells cannot choose another result after search replaces the grid")
    func staleAccessibilityAdverse() throws {
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        var chosen: [String] = []
        picker.onChoose = { chosen.append($0) }
        picker.setSearch("grinning")
        let old = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        let original = old.accessibilityValue() as? String
        picker.setSearch("france")
        #expect(picker.visibleItems.first?.emoji != original)
        #expect(!old.accessibilityPerformPress())
        #expect(chosen.isEmpty)
    }

    @Test("The picker delegate refuses a commit while its field editor has marked text")
    func pickerMarkedTextAdverse() throws {
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        var chosen: [String] = []
        picker.onChoose = { chosen.append($0) }
        picker.loadViewIfNeeded()
        let window = hiddenWindow()
        defer { window.close() }
        window.contentView = picker.view
        window.makeFirstResponder(picker.search)
        let editor = try #require(picker.search.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        _ = picker.control(picker.search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(chosen.isEmpty)
        #expect(!window.isVisible)
    }

    @Test("A never-presented picker releases normally; cancellation rejects retained callbacks")
    func unpresentedOwnership() {
        weak var released: SpaceIconPicker?
        autoreleasepool {
            let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
            released = picker
            picker.loadViewIfNeeded()
            var chosen: [String] = []
            picker.onChoose = { chosen.append($0) }
            picker.cancel()
            picker.choose("🧪")
            #expect(chosen.isEmpty)
        }
        #expect(released == nil)
    }

    @Test("Inline rename selects all, refuses marked Return, cancels on Escape and rejects stale end notifications")
    func inlineIMEAndSelection() throws {
        let window = hiddenWindow()
        defer { window.close() }
        let page = SidebarSpacePageView(frame: NSRect(x: 0, y: 0, width: 228, height: 640))
        window.contentView = page
        page.spaceID = SpaceID()
        page.list.subviews.compactMap { $0 as? SidebarSpaceTitleLabel }.first?.stringValue = "Synthetic original"
        var chosen: [String] = []
        #expect(page.beginSpaceRename { chosen.append($0) })
        let field = try #require(page.list.subviews.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "space-title-editor" })
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: 0, length: field.stringValue.utf16.count))
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(page.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(chosen.isEmpty && page.isRenamingSpace)
        #expect(page.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        page.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(chosen.isEmpty && !page.isRenamingSpace && !window.isVisible)
    }

    @Test("Native field-editor focus loss commits exactly once without showing its window")
    func inlineNativeBlur() throws {
        let window = hiddenWindow()
        defer { window.close() }
        let page = SidebarSpacePageView(frame: NSRect(x: 0, y: 0, width: 228, height: 640))
        page.geometry = OrbitSidebarGeometry.resolve(.init(width: 228, height: 640))
        window.contentView = page
        var names: [String] = []
        #expect(page.beginSpaceRename { names.append($0) })
        let field = try #require(page.list.subviews.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "space-title-editor" })
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.string = "  Synthetic blur  "
        #expect(window.makeFirstResponder(nil))
        #expect(names == ["Synthetic blur"] && !page.isRenamingSpace)
        page.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(names == ["Synthetic blur"] && !window.isVisible)
    }

    @Test("Refused first-responder admission rolls back the inline editor")
    func inlineFocusRefusalAdverse() {
        let window = RefusingRenameFieldWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let page = SidebarSpacePageView(frame: .zero)
        window.contentView = page
        #expect(!page.beginSpaceRename { _ in })
        #expect(!page.isRenamingSpace && !window.isVisible)
    }

    @Test("A real session profile switch and the production Quit freeze cancel inline drafts")
    func inlineSwitchAndQuitFreeze() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let originalPage = controller.sidebar.page
        var names: [String] = []
        #expect(originalPage.beginSpaceRename { names.append($0) })
        let otherProfile = await environment.store.createProfile(name: "Synthetic review profile")
        let other = try await environment.store.createSpace(name: "Synthetic review Space", profileID: otherProfile)
        controller.session.activateSpace(other)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.activeProfileID == otherProfile)
        #expect(!originalPage.isRenamingSpace && names.isEmpty)
        #expect(controller.sidebar.page.beginSpaceRename { names.append($0) })
        controller.freezeCommandsForTermination()
        #expect(!controller.sidebar.page.isRenamingSpace && names.isEmpty)
        #expect(!controller.sidebar.swipeCanInteract && controller.window?.isVisible == false)
        controller.cancelTerminationPreparation()
        #expect(!controller.sidebar.page.isRenamingSpace && names.isEmpty)
    }

    @Test("A picker choice queued behind a profile switch cannot write either Space")
    func pickerQueuedProfileAuthority() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let original = try #require(controller.session.snapshot?.activeSpaceID)
        let picker = try #require(controller.makeSpaceIconPicker(for: original))
        let otherProfile = await environment.store.createProfile(name: "Synthetic second profile")
        let other = try await environment.store.createSpace(name: "Synthetic second Space", profileID: otherProfile)
        controller.session.activateSpace(other)
        picker.choose("🧪")
        await controller.session.waitForPendingCommands()
        // The picker task may resume only after this wait; drain MainActor turns without a GUI run.
        for _ in 0..<20 { await Task.yield(); try await Task.sleep(for: .milliseconds(2)) }
        #expect(environment.settings.document.space(original).icon.isEmpty)
        #expect(environment.settings.document.space(other).icon.isEmpty)
        #expect(controller.window?.isVisible == false)
    }

    private func hiddenWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}
}

@MainActor
private final class RefusingRenameFieldWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextField { return false }
        return super.makeFirstResponder(responder)
    }
}
