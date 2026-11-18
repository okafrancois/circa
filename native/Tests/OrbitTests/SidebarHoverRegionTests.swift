import AppKit
import Testing
@testable import Orbit

struct SidebarHoverRegionTests {
    @Test func tracksTriggerDiagonalCorridorAndPopover() {
        let region = SidebarHoverRegion(trigger: NSRect(x: 0, y: 80, width: 40, height: 40),
                                       popover: NSRect(x: 60, y: 0, width: 100, height: 75))
        #expect(region.contains(NSPoint(x: 1, y: 119)))
        #expect(region.contains(NSPoint(x: 50, y: 77)))
        #expect(region.contains(NSPoint(x: 159, y: 1)))
        #expect(!region.contains(NSPoint(x: 10, y: 10)))
        #expect(!region.contains(NSPoint(x: 150, y: 115)))
    }

    @Test func routesPanelBeforeTriggerAndSeparatesTheTransferGap() {
        let region = SidebarHoverRegion(trigger: NSRect(x: 0, y: 80, width: 50, height: 40),
                                       popover: NSRect(x: 45, y: 0, width: 100, height: 85))
        #expect(region.destination(at: NSPoint(x: 47, y: 82)) == .panel)
        #expect(region.destination(at: NSPoint(x: 20, y: 100)) == .trigger)
        #expect(region.destination(at: NSPoint(x: 60, y: 90)) == .corridor)
        #expect(region.destination(at: NSPoint(x: 120, y: 105)) == .outside)
    }

    @Test @MainActor func windowHitsOnlyThePreviewInThePanelAndCorridor() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 200)
        let root = OrbitWindowRootView(frame: bounds)
        let window = OrbitBrowserWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        let background = NSView(frame: bounds)
        let trigger = NSView(frame: NSRect(x: 10, y: 80, width: 30, height: 30))
        let panel = SidebarHoverPopoverSurface(frame: NSRect(x: 60, y: 20, width: 100, height: 70))
        root.addSubview(background)
        root.addSubview(trigger)
        root.addSubview(panel)
        let popover = SidebarHoverPopover(closeDelay: 0)
        popover.start(trigger: trigger, popover: panel)
        defer { popover.stop() }

        let cardPoint = NSPoint(x: 70, y: 50)
        let gapPoint = NSPoint(x: 50, y: 85)
        let triggerPoint = NSPoint(x: 15, y: 90)
        #expect(root.hitTest(cardPoint) === panel)
        #expect(root.hitTest(gapPoint) === panel)
        #expect(root.hitTest(triggerPoint) === trigger)
        #expect(window.ownsPopoverHover(at: triggerPoint))
        #expect(!window.permitsHover(for: background, at: gapPoint))
        #expect(window.permitsHover(for: panel, at: cardPoint))

        popover.stop()
        #expect(root.hitTest(cardPoint) === background)
        #expect(root.hitTest(gapPoint) === background)
        #expect(window.permitsHover(for: background, at: gapPoint))
    }

    @Test @MainActor func routesWheelToThePanelAndConsumesTransferGapWheelInput() throws {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 200)
        let root = OrbitWindowRootView(frame: bounds)
        let window = OrbitBrowserWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        let trigger = NSView(frame: NSRect(x: 10, y: 80, width: 30, height: 30))
        let panel = SidebarHoverPopoverSurface(frame: NSRect(x: 60, y: 20, width: 100, height: 70))
        let receiver = RecordingScrollView(frame: panel.bounds)
        panel.addSubview(receiver)
        panel.scrollReceiver = receiver
        root.addSubview(trigger)
        root.addSubview(panel)
        let popover = SidebarHoverPopover(closeDelay: 0)
        popover.start(trigger: trigger, popover: panel)
        defer { popover.stop() }

        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                        wheel1: -40, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        let panelPoint = NSPoint(x: 70, y: 50)
        #expect(window.routePopoverScroll(wheel, at: panelPoint))
        #expect(window.routePopoverScroll(wheel, at: NSPoint(x: 50, y: 85)))
        #expect(window.routePopoverScroll(wheel, at: NSPoint(x: 20, y: 95)))
        #expect(!window.routePopoverScroll(wheel, at: NSPoint(x: 180, y: 105)))
        #expect(receiver.events == [wheel])

        popover.stop()
        #expect(!window.routePopoverScroll(wheel, at: panelPoint))
    }

    @Test func tracksResizedAndMirroredGeometry() {
        let popover = NSRect(x: 0, y: 50, width: 200, height: 130)
        let point = NSPoint(x: 247, y: 194)
        let initial = SidebarHoverRegion(trigger: NSRect(x: 220, y: 192, width: 28, height: 28), popover: popover)
        let resized = SidebarHoverRegion(trigger: NSRect(x: 200, y: 260, width: 28, height: 28), popover: popover)
        #expect(initial.contains(point))
        #expect(!resized.contains(point))
        #expect(resized.contains(NSPoint(x: 201, y: 261)))
    }

    @Test func coversTheGapAboveTheDownloadsButton() {
        let region = SidebarHoverRegion(trigger: NSRect(x: 10, y: 11, width: 28, height: 28),
                                        popover: NSRect(x: 0, y: 39.5, width: 250, height: 112))
        #expect(region.contains(NSPoint(x: 11, y: 38)))
        #expect(region.contains(NSPoint(x: 24, y: 39.25)))
        #expect(region.contains(NSPoint(x: 200, y: 80)))
        #expect(!region.contains(NSPoint(x: 200, y: 28)))
    }

    @Test func removedOrClippedTriggerInvalidatesTheRegion() {
        let popover = NSRect(x: 40, y: 20, width: 250, height: 250)
        let point = NSPoint(x: 120, y: 130)
        #expect(!SidebarHoverRegion(trigger: nil, popover: popover).contains(point))
        #expect(!SidebarHoverRegion(trigger: .zero, popover: popover).contains(point))
    }

    @Test @MainActor func windowGeometryIsLimitedToViewBoundsAndDiscardedOnRemoval() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        let panel = NSView(frame: NSRect(x: 30, y: 40, width: 100, height: 80))
        panel.clipsToBounds = false
        root.addSubview(panel)
        #expect(SidebarHoverPopover.visibleRect(of: panel, in: window) == panel.convert(panel.bounds, to: nil))

        panel.removeFromSuperview()
        #expect(SidebarHoverPopover.visibleRect(of: panel, in: window) == nil)
    }

    @Test @MainActor func mouseMovesRemainEnabledUntilTheLastClientReleasesThem() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.acceptsMouseMovedEvents = false
        let first = OrbitMouseMoveTracking(in: window)
        let second = OrbitMouseMoveTracking(in: window)
        #expect(window.acceptsMouseMovedEvents)
        first.cancel()
        first.cancel()
        #expect(window.acceptsMouseMovedEvents)
        second.cancel()
        #expect(!window.acceptsMouseMovedEvents)

        window.acceptsMouseMovedEvents = true
        let alreadyEnabled = OrbitMouseMoveTracking(in: window)
        alreadyEnabled.cancel()
        #expect(window.acceptsMouseMovedEvents)
    }
}


@MainActor
private final class RecordingScrollView: NSScrollView {
    private(set) var events: [NSEvent] = []

    override func scrollWheel(with event: NSEvent) { events.append(event) }
}
