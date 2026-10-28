import AppKit
import Foundation
import Testing
@testable import Orbit
import BrowserEngine
import WebKitEngine

/// Offscreen renders of the window shell for the lot's own visual checks. Disabled unless
/// `ORBIT_THEME_SNAPSHOT_DIR` names an output directory. Layer rendering omits masks and remote
/// (web) layers, so these images are a geometry/colour aid, never an equivalence proof.
extension NativeWebKitTests {
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_THEME_SNAPSHOT_DIR"] != nil))
@MainActor
struct ThemeSnapshotDiagnostics {
    private func render(_ controller: PreviewWindowController, named name: String) throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ORBIT_THEME_SNAPSHOT_DIR"]))
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        root.display()
        let scale: CGFloat = 2
        let size = root.bounds.size
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        func displayTree(_ layer: CALayer) {
            layer.displayIfNeeded()
            layer.sublayers?.forEach(displayTree)
        }
        if let layer = root.layer {
            displayTree(layer)
            // Bitmap contexts are unflipped; the root layer is too.
            layer.render(in: context.cgContext)
        }
        // Window buttons live in the title bar, outside the content layer tree: draw markers at
        // their frames so the placement is visible in the render.
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), !button.isHidden else { continue }
            let frame = button.convert(button.bounds, to: nil)
            let circle = NSRect(x: frame.midX - 6, y: frame.midY - 6, width: 12, height: 12)
            context.cgContext.setFillColor(type == .closeButton ? NSColor.systemRed.cgColor
                                           : type == .miniaturizeButton ? NSColor.systemYellow.cgColor : NSColor.systemGreen.cgColor)
            context.cgContext.fillEllipse(in: circle)
        }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func makeWindow(appearance: NSAppearance.Name) async throws -> PreviewWindowController {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(NSSize(width: 1024, height: 640))
        controller.openTab()
        controller.openTab()
        await controller.session.waitForPendingCommands()
        let profile = try #require(controller.session.catalog?.profiles.first?.id)
        controller.createSpace(name: "Lab B", profileID: profile)
        await controller.session.waitForPendingCommands()
        controller.activateSpace(try #require(controller.session.catalog?.spaces.first?.id))
        await controller.session.waitForPendingCommands()
        return controller
    }

    @Test func renderStates() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let controller = try await makeWindow(appearance: appearance)
            defer { controller.window?.close() }
            try render(controller, named: "docked-\(suffix)")
            controller.toggleSidebar()
            await controller.session.waitForPendingCommands()
            try render(controller, named: "hidden-\(suffix)")
            controller.windowShell.setFloating(true, animated: false)
            try render(controller, named: "floating-\(suffix)")
            controller.toggleSidebar()
            await controller.session.waitForPendingCommands()
            controller.windowShell.setSidebarWidth(180)
            try render(controller, named: "min-width-\(suffix)")
            controller.windowShell.setSidebarWidth(420)
            try render(controller, named: "max-width-\(suffix)")
        }
        let saved = OrbitSpaceThemes.resolver
        defer { OrbitSpaceThemes.resolver = saved }
        OrbitSpaceThemes.resolver = { _, _ in .amberCoral }
        let themed = try await makeWindow(appearance: .aqua)
        defer { themed.window?.close() }
        try render(themed, named: "theme-amber-light")
    }
}
}
