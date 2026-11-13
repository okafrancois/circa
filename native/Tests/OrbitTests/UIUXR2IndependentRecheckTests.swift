import AppKit
@testable import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

/// Independent exact-source recheck. All windows remain hidden; panel ordering is forbidden.
extension NativeWebKitTests {
@Suite("UI R2 independent recheck", .serialized)
@MainActor
struct UIUXR2IndependentRecheckTests {
    @Test("The final AppKit-aligned circle remains inside its dense target")
    func alignedDrawingContainment() {
        let window = hiddenWindow()
        defer { window.close() }
        let footer = SidebarFooterView()
        window.contentView = footer
        let profile = ProfileID()
        for (width, count): (CGFloat, Int) in [(180, 40), (228, 60), (228, 64), (400, 200)] {
            let spaces = (0..<count).map { BrowserSpace(id: SpaceID(), profileID: profile, name: "Synthetic \($0)") }
            footer.render(spaces: spaces, activeSpaceID: spaces.first?.id)
            let geometry = OrbitSidebarGeometry.resolve(.init(width: width, height: 640, spaceCount: count))
            footer.frame = geometry.footerFrame
            footer.apply(geometry)
            var escaped = 0
            var maximumOverflow: CGFloat = 0
            var firstWitness = ""
            for button in footer.spaceButtons where button.dotDiameter > 0 {
                let d = button.dotDiameter
                // This is the same native alignment operation used by customDrawing, after
                // attachment to a real hidden backing window; no bitmap or physical claim.
                let circle = button.backingAlignedRect(NSRect(x: button.bounds.midX - d / 2,
                    y: button.bounds.midY - d / 2, width: d, height: d), options: .alignAllEdgesNearest)
                if circle.minX < button.bounds.minX - 0.0001 || circle.maxX > button.bounds.maxX + 0.0001 {
                    escaped += 1
                    maximumOverflow = max(maximumOverflow, max(button.bounds.minX - circle.minX, circle.maxX - button.bounds.maxX))
                    if firstWitness.isEmpty { firstWitness = "target \(button.index): bounds \(button.bounds), circle \(circle)" }
                }
            }
            #expect(escaped == 0, "width \(width), count \(count), scale \(window.backingScaleFactor), escaped circles \(escaped), maximum overflow \(maximumOverflow); \(firstWitness)")
        }
        #expect(!window.isVisible)
    }

    @Test("A retained AX cell does not keep its picker or grid alive and refuses after teardown")
    func retainedAccessibilityLifetime() throws {
        weak var weakPicker: SpaceIconPicker?
        weak var weakGrid: SpaceIconGridView?
        var retained: NSAccessibilityElement?
        autoreleasepool {
            let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
            picker.setSearch("grinning")
            weakPicker = picker
            weakGrid = picker.grid
            retained = (picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first
        }
        let cell = try #require(retained)
        #expect(weakPicker == nil)
        #expect(weakGrid == nil)
        #expect(!cell.accessibilityPerformPress())
    }

    @Test("An AX query ABA remains revoked; a foreign-thread refusal leaves a fresh main-thread action usable")
    func accessibilityABAAndThreadRecovery() async throws {
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        picker.setSearch("grinning")
        let old = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        let value = old.accessibilityValue() as? String
        picker.setSearch("france")
        picker.setSearch("grinning")
        #expect(picker.visibleItems.first?.emoji == value)
        var chosen: [String] = []
        picker.onChoose = { chosen.append($0) }
        #expect(!old.accessibilityPerformPress())
        let fresh = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        let reference = RecheckAXReference(fresh)
        #expect(await Task.detached { reference.element.accessibilityPerformPress() }.value == false)
        #expect(chosen.isEmpty)
        #expect(fresh.accessibilityPerformPress())
        #expect(chosen == [value])
        #expect(!fresh.accessibilityPerformPress())
    }

    @Test("Marked text blocks delegate commands, direct removal and AX until composition ends")
    func compositionRecovery() throws {
        let picker = SpaceIconPicker(currentIcon: "🧪", accent: .defaultSpace)
        picker.setSearch("grinning")
        let window = hiddenWindow()
        defer { window.close() }
        window.contentView = picker.view
        #expect(window.makeFirstResponder(picker.search))
        let editor = try #require(picker.search.currentEditor() as? NSTextView)
        let cell = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        var chosen: [String] = []
        picker.onChoose = { chosen.append($0) }
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.moveUp(_:)), #selector(NSResponder.cancelOperation(_:))] {
            #expect(!picker.control(picker.search, textView: editor, doCommandBy: selector))
        }
        picker.removeIcon(nil)
        picker.choose("👩🏽‍💻")
        _ = picker.handle(#selector(NSResponder.insertNewline(_:)))
        #expect(!cell.accessibilityPerformPress())
        #expect(chosen.isEmpty && editor.hasMarkedText())
        editor.unmarkText()
        // Native text notifications legitimately regenerate results while composing.
        // A stale cell must remain revoked even after unmarking; use the current generation.
        #expect(!cell.accessibilityPerformPress())
        picker.setSearch("👩🏽‍💻")
        let current = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        #expect(current.accessibilityPerformPress())
        #expect(chosen == ["👩🏽‍💻"] && !window.isVisible)
    }

    @Test("Tab delegates to native key-view eligibility with functional Icons search")
    func nativeKeyViewTraversal() throws {
        let picker = SpaceIconPicker(currentIcon: "🧪", accent: .defaultSpace)
        picker.loadViewIfNeeded()
        let window = hiddenWindow()
        defer { window.close() }
        window.autorecalculatesKeyViewLoop = false
        window.contentView = picker.view
        #expect(window.makeFirstResponder(picker.search))
        let editor = try #require(picker.search.currentEditor() as? NSTextView)
        #expect(!picker.control(picker.search, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        let next = picker.search.nextValidKeyView
        window.selectNextKeyView(picker.search)
        if let next, next !== picker.search {
            #expect(window.firstResponder === next || (next as? NSControl)?.currentEditor() === window.firstResponder)
        } else {
            // Native text-only keyboard navigation may leave search as the sole eligible
            // control. Do not change the machine preference or claim every button was reached.
            #expect(picker.search.currentEditor() != nil)
            #expect(!NSApplication.shared.isFullKeyboardAccessEnabled)
        }
        picker.modes.selectedSegment = SpaceIconPicker.Mode.icons.rawValue
        _ = picker.modes.sendAction(picker.modes.action, to: picker.modes.target)
        #expect(picker.search.isEnabled)
        #expect(window.makeFirstResponder(picker.modes))
        window.selectNextKeyView(picker.modes)
        #expect(picker.search.currentEditor() != nil && !window.isVisible)
    }

    @Test("Focus refusal removes the editor, restores the title and permits a complete later rename")
    func renameRefusalThenRecovery() throws {
        let window = RecheckRefusingFieldWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let page = SidebarSpacePageView(frame: .zero)
        window.contentView = page
        var names: [String] = []
        #expect(!page.beginSpaceRename { names.append($0) })
        #expect(!page.isRenamingSpace && names.isEmpty)
        #expect(page.list.subviews.compactMap { $0 as? SidebarSpaceTitleLabel }.first?.isHidden == false)
        #expect(page.list.subviews.allSatisfy { ($0 as? NSTextField)?.accessibilityIdentifier() != "space-title-editor" })
        window.refusesFields = false
        #expect(page.beginSpaceRename { names.append($0) })
        let field = try #require(page.list.subviews.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "space-title-editor" })
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: 0, length: field.stringValue.utf16.count))
        editor.string = "Synthetic recovered rename"
        #expect(window.makeFirstResponder(nil))
        #expect(names == ["Synthetic recovered rename"] && !page.isRenamingSpace && !window.isVisible)
    }

    @Test("Every callback stage rejects removed, reprofiled, hidden, detached and cancelled picker authority",
        arguments: [0, 1, 2])
    func presentationRevocationMatrix(stage: Int) {
        for mutation in 0..<7 {
            let window = GuardedRecheckWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 640),
                styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let footer = SidebarFooterView()
            defer {
                footer.onMenuWillOpen = nil
                footer.onHoverSpace = nil
                footer.onMenuPresentationChange = nil
            }
            let space = BrowserSpace(id: SpaceID(), profileID: ProfileID(), name: "Synthetic target")
            footer.render(spaces: [space], activeSpaceID: space.id)
            window.contentView?.addSubview(footer)
            let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
            var revoked = false
            let revoke: () -> Void = {
                guard !revoked else { return }
                revoked = true
                switch mutation {
                case 0: footer.setCommandsEnabled(false)
                case 1: footer.render(spaces: [], activeSpaceID: nil)
                case 2:
                    footer.render(spaces: [.init(id: space.id, profileID: ProfileID(), name: space.name)], activeSpaceID: space.id)
                case 3: footer.isHidden = true
                case 4: footer.removeFromSuperview()
                case 5: window.reportsVisible = false
                default: picker.cancel()
                }
            }
            if stage == 0 { footer.onMenuWillOpen = revoke }
            if stage == 1 { footer.onHoverSpace = { _ in revoke() } }
            if stage == 2 { footer.onMenuPresentationChange = revoke }
            #expect(!footer.presentIconPicker(picker, for: space.id))
            #expect(revoked && footer.iconPicker == nil && picker.popup.window == nil)
        }
    }

    @Test("Closing an existing context menu can revoke the pending picker before later callbacks")
    func contextCancellationReentrancy() throws {
        let window = GuardedRecheckWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 640),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let footer = SidebarFooterView()
        defer { footer.onMenuPresentationChange = nil }
        let space = BrowserSpace(id: SpaceID(), profileID: ProfileID(), name: "Synthetic target")
        footer.render(spaces: [space], activeSpaceID: space.id)
        window.contentView?.addSubview(footer)
        footer.showContextMenu(for: footer.spaceButtons[0], present: false)
        _ = try #require(footer.contextMenu)
        footer.onMenuPresentationChange = { window.reportsVisible = false }
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        #expect(!footer.presentIconPicker(picker, for: space.id))
        #expect(footer.contextMenu == nil && footer.iconPicker == nil && picker.popup.window == nil)
    }

    @Test("A visible sheet request is refused when its source becomes hidden before the command queue runs")
    func queuedHiddenFallback() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        let originalWindow = controller.window
        let window = GuardedRecheckWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 640),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            controller.window = originalWindow
            environment.autoArchive.scheduler.stop()
            originalWindow?.close()
            window.close()
        }
        controller.window = window
        controller.sidebar.isHidden = true
        let id = try #require(controller.session.snapshot?.activeSpaceID)
        #expect(controller.makeSpaceIconEditor(for: id) != nil)
        controller.presentSpaceIconEditor(for: id)
        #expect(controller.session.hasPendingCommands)
        window.reportsVisible = false
        await controller.session.waitForPendingCommands()
        #expect(window.attachedSheet == nil && controller.sidebar.footer.iconPicker == nil)
    }

    private func hiddenWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}
}

/// The source fixture cannot order a window or attach a panel/sheet. Unexpected presentation
/// aborts before the popup can proceed from addChildWindow to makeKeyAndOrderFront.
@MainActor
private final class GuardedRecheckWindow: NSWindow {
    var reportsVisible = true
    override var isVisible: Bool { reportsVisible }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        precondition(place == .out, "Independent hidden fixture must never be ordered")
        super.order(place, relativeTo: otherWin)
    }
    override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
        preconditionFailure("Independent hidden fixture must never attach a popup")
    }
    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        preconditionFailure("Independent hidden fixture must never present a sheet")
    }
}

@MainActor
private final class RecheckRefusingFieldWindow: NSWindow {
    var refusesFields = true
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if refusesFields, responder is NSTextField { return false }
        return super.makeFirstResponder(responder)
    }
}

private final class RecheckAXReference: @unchecked Sendable {
    let element: NSAccessibilityElement
    init(_ element: NSAccessibilityElement) { self.element = element }
}
