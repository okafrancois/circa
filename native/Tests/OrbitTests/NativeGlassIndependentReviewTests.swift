import AppKit
import Testing
@testable import Orbit

/// Independent detached-view checks. No window, engine, preference write or session access.
extension NativeWebKitTests {
@Suite("Independent glass notification and lifetime review", .serialized)
@MainActor
struct NativeGlassIndependentReviewTests {
    @Test("Workspace accessibility notifications refresh a live fill and do not retain released fills")
    func workspaceNotificationAndLifetime() {
        weak var releasedFill: OrbitThemeFillView?
        var refreshCount = 0
        autoreleasepool {
            let fill = OrbitThemeFillView(materialRole: .windowShell)
            releasedFill = fill
            fill.onMaterialChange = { refreshCount += 1 }
            // Deliberately stale style: delivery must recompute from the workspace, not keep it.
            fill.applyMaterialStyle(OrbitGlassStyle(usesMaterial: false, tintOpacity: 0.123,
                                                 emphasizesBoundary: false))
            let before = refreshCount
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            #expect(refreshCount == before + 1)
            #expect(fill.glassStyle.tintOpacity != 0.123)
            let fallback = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            #expect(fill.materialView?.isHidden == fallback)
            #expect(fill.glassStyle.usesMaterial == !fallback)
        }
        #expect(releasedFill == nil)
        let before = refreshCount
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(refreshCount == before)
    }

    @Test("Appearance refresh leaves another themed fill unchanged and decorative siblings preserve picking")
    func appearanceIsolationAndPicking() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let fill = OrbitThemeFillView(materialRole: .windowShell)
        fill.frame = root.bounds
        let other = OrbitThemeFillView(materialRole: .windowShell)
        other.appearance = NSAppearance(named: .darkAqua)
        other.apply(.lavender)
        let otherStops = other.resolvedStops
        let button = NSButton(frame: NSRect(x: 20, y: 20, width: 100, height: 40))
        root.addSubview(fill)
        root.addSubview(button)
        #expect(root.hitTest(NSPoint(x: 50, y: 40)) === button)
        #expect(root.hitTest(NSPoint(x: 200, y: 100)) === root)
        fill.appearance = NSAppearance(named: .aqua)
        let lightStops = fill.resolvedStops
        fill.appearance = NSAppearance(named: .darkAqua)
        fill.viewDidChangeEffectiveAppearance()
        #expect(fill.resolvedStops != lightStops)
        #expect(other.resolvedStops == otherStops && other.theme == .lavender)
        #expect(other.materialView !== fill.materialView)
        let toolbar = BrowserQuickWindowToolbarView(frame: root.bounds)
        #expect(toolbar.fill.materialView == nil)
        #expect(toolbar.fill.glassStyle.tintOpacity == 1)
    }
}
}
