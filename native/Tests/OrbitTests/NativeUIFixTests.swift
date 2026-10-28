import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("UI-FIX-1 hidden regressions", .serialized)
@MainActor
struct NativeUIFixTests {
    @Test("Pane bars re-resolve their layers when attached to a light window and when appearance changes")
    func paneAppearance() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = PaneAppearanceWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = BrowserSplitPaneView(id: TabID())
        pane.frame = .init(x: 0, y: 0, width: 500, height: 400)
        pane.appearance = NSAppearance(named: .darkAqua)
        var accent = OrbitTokens.ThemeAccent.defaultPurple
        accent.strong = OrbitTokens.Color.Text.vibrant
        pane.setActive(true, accent: accent)
        #expect(pane.clip.layer?.backgroundColor == OrbitTokens.Color.Surface.splitToolbar.resolvedCGColor(for: pane.effectiveAppearance))
        window.contentView?.addSubview(pane)
        pane.appearance = nil
        for mode in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            window.appearance = NSAppearance(named: mode)
            pane.layoutSubtreeIfNeeded()
            let appearance = pane.effectiveAppearance
            #expect(pane.clip.layer?.backgroundColor == OrbitTokens.Color.Surface.splitToolbar.resolvedCGColor(for: appearance))
            #expect(pane.focusBorder.borderColor == accent.splitFocusBorder.resolvedCGColor(for: appearance))
            if mode == .aqua {
                #expect(pane.focusBorder.borderColor == accent.strong.resolvedCGColor(for: appearance))
            } else {
                #expect(pane.focusBorder.borderColor == NSColor(srgbRed: 41/255, green: 50/255, blue: 254/255, alpha: 1).cgColor)
            }
            #expect(pane.line.layer?.backgroundColor == OrbitTokens.Color.Line.floatingScrimBorder.resolvedCGColor(for: appearance))
            #expect(pane.focusBorder.borderWidth == OrbitTokens.Metrics.Content.splitFocusBorderWidth)
            for key in [false, true, false] {
                window.testIsKey = key
                NotificationCenter.default.post(name: key ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: window)
                let keyBackground = key ? OrbitTokens.Color.Surface.splitToolbarEmphasized : OrbitTokens.Color.Surface.splitToolbar
                #expect(pane.clip.layer?.backgroundColor == keyBackground.resolvedCGColor(for: appearance))
                for active in [false, true] {
                    pane.setActive(active, accent: accent)
                    let emphasized = active && key
                    let background = emphasized ? OrbitTokens.Color.Surface.splitToolbarEmphasized : OrbitTokens.Color.Surface.splitToolbar
                    let foreground = emphasized ? OrbitTokens.Color.Text.splitToolbarEmphasized : OrbitTokens.Color.Text.splitToolbar
                    #expect(pane.clip.layer?.backgroundColor == background.resolvedCGColor(for: appearance))
                    for button in [pane.address, pane.close, pane.back, pane.forward, pane.reload, pane.siteControls, pane.splitToggle] {
                        #expect(button.contentTintColor?.resolved(for: appearance) == foreground.resolved(for: appearance))
                    }
                    #expect(pane.focusBorder.opacity == (active ? 1 : 0))
                    #expect(pane.layer?.shadowRadius == (active ? OrbitTokens.Shadow.splitActiveHalo : OrbitTokens.Shadow.contentCard).blur / 2)
                    #expect(pane.accessibilityValue() as? String == (active ? BrowserSplitStrings.activePane : BrowserSplitStrings.visiblePane))
                    #expect(contrastRatio(foreground: foreground.resolved(for: appearance), background: background.resolved(for: appearance)) >= 4.5)
                }
            }
        }
        pane.setActive(false, accent: .defaultPurple)
        #expect(pane.focusBorder.opacity == 0 && pane.layer?.shadowOpacity == 1)
        #expect(pane.layer?.shadowRadius == OrbitTokens.Shadow.contentCard.blur / 2)
        #expect(!window.isVisible)
    }

    @Test("A sidebar payload traverses AppKit destination callbacks at all four content-card edges",
          arguments: [0, 1, 2, 3])
    func edgeDrop(edge: Int) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.session.close(); controller.window?.close() }
        controller.session.openTab(url: URL(string: "https://ui-fix.test/source")!)
        await controller.session.waitForPendingCommands()
        let source = try #require(controller.session.organization?.selectedTab?.id)
        controller.session.openTab(url: URL(string: "https://ui-fix.test/target")!)
        await controller.session.waitForPendingCommands()
        controller.session.addSplitPane(url: URL(string: "https://ui-fix.test/second")!)
        await controller.session.waitForPendingCommands()
        let group = try #require(controller.session.activeSplit)
        let list = controller.sidebar.page.list
        let payload = try #require(controller.sidebar.list(list, dragPayloadFor: .tab(source), grabOffsetX: 8))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([payload.pasteboardItem()]))
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let view = controller.split.view
        let bounds = view.bounds
        #expect(bounds.width > 0 && bounds.height > 0)
        let points = [CGPoint(x: bounds.minX + 5, y: bounds.midY), CGPoint(x: bounds.maxX - 5, y: bounds.midY),
                      CGPoint(x: bounds.midX, y: bounds.minY + 5), CGPoint(x: bounds.midX, y: bounds.maxY - 5)]
        let info = UIHiddenDraggingInfo(window: window, pasteboard: pasteboard, source: list,
                                       location: view.convert(points[edge], to: nil))
        // Check the hit-tested destination as well as callbacks: a direct model call bypasses both.
        var destination = window.contentView?.hitTest(info.draggingLocation)
        while let current = destination, !current.registeredDraggedTypes.contains(SidebarDragPayload.pasteboardType) {
            destination = current.superview
        }
        #expect(destination === view)
        let center = UIHiddenDraggingInfo(window: window, pasteboard: pasteboard, source: list,
            location: view.convert(.init(x: bounds.midX, y: bounds.midY), to: nil))
        #expect(view.draggingEntered(center).isEmpty)
        #expect(!view.performDragOperation(center))
        #expect(view.registeredDraggedTypes.contains(SidebarDragPayload.pasteboardType))
        #expect(view.draggingEntered(info) == .move)
        #expect(view.draggingUpdated(info) == .move)
        #expect(view.prepareForDragOperation(info))
        #expect(view.performDragOperation(info))
        await controller.session.waitForPendingCommands()
        let updated = try #require(controller.session.activeSplit)
        #expect(updated.group.id == group.group.id)
        #expect(updated.group.tabIDs.count == 3)
        #expect(updated.group.orientation == (edge < 2 ? .horizontal : .vertical))
        #expect((edge % 2 == 0 ? updated.group.tabIDs.first : updated.group.tabIDs.last) == source)
        #expect(!window.isVisible)
    }
}
}

@MainActor
private final class PaneAppearanceWindow: NSWindow {
    var testIsKey = false
    override var isKeyWindow: Bool { testIsKey }
}

private func contrastRatio(foreground: NSColor, background: NSColor) -> CGFloat {
    func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB)!
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let alpha = c.alphaComponent
        let back = background.usingColorSpace(.sRGB)!
        return 0.2126 * linear(c.redComponent * alpha + back.redComponent * (1 - alpha))
             + 0.7152 * linear(c.greenComponent * alpha + back.greenComponent * (1 - alpha))
             + 0.0722 * linear(c.blueComponent * alpha + back.blueComponent * (1 - alpha))
    }
    let a = luminance(foreground), b = luminance(background)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// Destination-protocol fixture; no OS mouse capture, drag image, activation or global pasteboard.
@MainActor
private final class UIHiddenDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingLocation: NSPoint
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, pasteboard: NSPasteboard, source: Any, location: NSPoint) {
        draggingDestinationWindow = window; draggingPasteboard = pasteboard
        draggingSource = source; draggingLocation = location
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
