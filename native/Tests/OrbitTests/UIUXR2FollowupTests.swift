import AppKit
@testable import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

/// Hidden responder and offscreen geometry tests; never order or activate a window or panel.
extension NativeWebKitTests {
@Suite("UI R2 review follow-ups", .serialized)
@MainActor
struct UIUXR2FollowupTests {
    @Test("Dense dots fit backing-pixel cells and omit unresolvable subpixel decorations")
    func physicalDotContainment() {
        for scale: CGFloat in [1, 2, 3] {
            for count in [40, 60, 200, 1000] {
                let layout = FooterSpaceLayout.resolve(count: count, libraryCenterX: 24,
                    plusCenterX: 156, backingScale: scale)
                #expect(layout.centerXs.count == count)
                #expect(layout.dotDiameter <= layout.pitch && layout.dotDiameter >= 0)
                #expect(abs(layout.dotDiameter * scale - floor(layout.dotDiameter * scale)) < 0.001)
                if layout.pitch < 1 / scale { #expect(layout.dotDiameter == 0) }
            }
        }
    }

    @Test("Tab traverses controls and does not consume emoji-grid selection")
    func pickerTabTraversal() {
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        picker.loadViewIfNeeded()
        let selected = picker.grid.selectedIndex
        #expect(!picker.handle(#selector(NSResponder.insertTab(_:))))
        #expect(!picker.handle(#selector(NSResponder.insertBacktab(_:))))
        #expect(picker.grid.selectedIndex == selected)
        var controls: [NSView] = []
        var next: NSView? = picker.modes
        for _ in 0..<20 {
            guard let control = next, !controls.contains(where: { $0 === control }) else { break }
            controls.append(control)
            next = control.nextKeyView
        }
        for required in [picker.modes, picker.search] as [NSView] {
            #expect(controls.contains(where: { $0 === required }))
        }
        // Emoji & Symbols and Remove Icon live in the grid's context menu, not in the key-view loop.
        let menuTitles = picker.grid.menu?.items.map(\.title) ?? []
        #expect(menuTitles.contains(picker.paletteButton.title))
        #expect(menuTitles.contains(picker.removeButton.title))
    }

    @Test("Disabled mode revokes retained AX cells across a switch back to Emoji")
    func modeGenerationRevocation() throws {
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        picker.setSearch("grinning")
        let retained = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        var chosen: [String] = []
        picker.onChoose = { chosen.append($0) }
        for mode in [SpaceIconPicker.Mode.icons, .emoji] {
            picker.modes.selectedSegment = mode.rawValue
            _ = picker.modes.sendAction(picker.modes.action, to: picker.modes.target)
            #expect(!retained.accessibilityPerformPress())
            #expect(chosen.isEmpty)
        }
        let fresh = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        #expect(fresh.accessibilityPerformPress())
        #expect(chosen.count == 1)
    }

    @Test("IME composition blocks both direct and retained AX commits")
    func compositionAcrossChoicePaths() throws {
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        picker.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = picker.view
        #expect(window.makeFirstResponder(picker.search))
        let fieldEditor = try #require(picker.search.currentEditor() as? NSTextView)
        let element = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        var chosen: [String] = []
        picker.onChoose = { chosen.append($0) }
        fieldEditor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(fieldEditor.hasMarkedText())
        picker.choose("🧪")
        #expect(!element.accessibilityPerformPress())
        #expect(chosen.isEmpty && !window.isVisible)
    }

    @Test("A foreign-thread AX callback refuses before accessing MainActor grid state")
    func foreignThreadAccessibilityRefusal() async throws {
        let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
        picker.setSearch("grinning")
        let element = try #require((picker.grid.accessibilityChildren() as? [NSAccessibilityElement])?.first)
        let retained = SendableAXTestReference(element)
        let accepted = await Task.detached { retained.element.accessibilityPerformPress() }.value
        #expect(!accepted)
    }

    @Test("Presentation callbacks can revoke footer admission before any panel is created")
    func callbackPresentationRevocation() {
        let space = BrowserSpace(id: SpaceID(), profileID: ProfileID(), name: "Synthetic Space")
        let footer = SidebarFooterView()
        footer.render(spaces: [space], activeSpaceID: space.id)
        let window = ReportedVisibleOnlyWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 640),
                                               styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = footer
        for stage in [0, 1] {
            footer.setCommandsEnabled(true)
            let picker = SpaceIconPicker(currentIcon: "", accent: .defaultSpace)
            footer.onMenuWillOpen = stage == 0 ? { footer.setCommandsEnabled(false) } : nil
            footer.onMenuPresentationChange = stage == 1 ? { footer.setCommandsEnabled(false) } : nil
            #expect(!footer.presentIconPicker(picker, for: space.id))
            #expect(footer.iconPicker == nil && picker.popup.window == nil)
        }
    }

    @Test("The controller's sheet fallback never exposes a hidden window")
    func hiddenControllerFallback() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        controller.presentSpaceIconEditor(for: space)
        await controller.session.waitForPendingCommands()
        #expect(controller.window?.isVisible == false)
        #expect(controller.window?.attachedSheet == nil)
        #expect(controller.sidebar.footer.iconPicker == nil)
    }
}
}

/// Reports visibility only to exercise source admission; the backing window is never ordered.
@MainActor
private final class ReportedVisibleOnlyWindow: NSWindow {
    override var isVisible: Bool { true }
}

/// Only the tested refusal entry point crosses threads; no mutable AX state is read there.
private final class SendableAXTestReference: @unchecked Sendable {
    let element: NSAccessibilityElement
    init(_ element: NSAccessibilityElement) { self.element = element }
}
