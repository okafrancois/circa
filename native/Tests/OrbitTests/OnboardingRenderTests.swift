import AppKit
import BrowserCore
import Foundation
import Testing
@testable import Orbit

/// Offscreen renders of every onboarding step and of a step push, frame by frame, for the lot's
/// side-by-side comparisons. Disabled unless `ORBIT_ONBOARDING_RENDER_DIR` names an output directory.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_ONBOARDING_RENDER_DIR"] != nil))
@MainActor
struct OnboardingRenderTests {
    static let sources: [OrbitOnboardingSource] = [
        .init(id: "brave", name: "Brave", bundleIdentifier: nil, profiles: []),
        .init(id: "chrome", name: "Chrome", bundleIdentifier: nil, profiles: [
            .init(directory: "Default", name: "Personal"), .init(directory: "Profile 1", name: "Work"),
            .init(directory: "Profile 2", name: "Side Project")
        ]),
        .init(id: "safari", name: "Safari", bundleIdentifier: nil, profiles: []),
        .init(id: "firefox", name: "Firefox", bundleIdentifier: nil, profiles: [.init(directory: "abc.default", name: "default")])
    ]

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORBIT_ONBOARDING_RENDER_DIR"]!)
    }

    static func makeController(step: BrowserOnboardingRecord.Step = .welcome, sync: OrbitOnboardingSyncAvailability = .available,
                               themed: BrowserSpaceTheme? = nil) -> OrbitOnboardingWindowController {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let flow = OrbitOnboardingFlow(step: step, sources: sources, syncAvailability: sync)
        var services = OrbitOnboardingServices()
        services.sourceArtwork = { source in OrbitOnboardingArtwork.artwork(for: source, synthetic: true) }
        let target = OrbitOnboardingThemeTarget(spaceID: SpaceID(), profileID: ProfileID(), stored: themed,
                                                commit: { _ in }, registry: nil)
        return OrbitOnboardingWindowController(flow: flow, services: services, themeTarget: target)
    }

    static func image(_ controller: OrbitOnboardingWindowController, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        root.display()
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
        let layer = try #require(root.layer)
        displayTree(layer)
        layer.render(in: context.cgContext)
        return bitmap
    }

    private func write(_ controller: OrbitOnboardingWindowController, _ name: String) throws {
        let data = try #require(try Self.image(controller).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    @Test func renderSteps() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            let welcome = Self.makeController()
            try write(welcome, "1-welcome-\(suffix)")
            let importing = Self.makeController(step: .importSource)
            try write(importing, "2-import-\(suffix)")
            importing.select(optionAt: 1)
            try write(importing, "2-import-profiles-\(suffix)")
            let sync = Self.makeController(step: .sync)
            sync.select(optionAt: 0)
            try write(sync, "3-sync-\(suffix)")
            let syncOff = Self.makeController(step: .sync, sync: .unavailable)
            try write(syncOff, "3-sync-unavailable-\(suffix)")
            let theme = Self.makeController(step: .theme)
            try write(theme, "4-theme-\(suffix)")
            theme.applyTheme(BrowserSpaceTheme.radial(colors: [BrowserThemeColor(hex: 0x2DD48C)], intensity: BrowserSpaceTheme.defaultIntensity,
                                                      noise: 0.3, mode: .light))
            try write(theme, "4-theme-picked-\(suffix)")
            let defaultBrowser = Self.makeController(step: .defaultBrowser)
            defaultBrowser.select(optionAt: 0)
            try write(defaultBrowser, "5-default-\(suffix)")
            defaultBrowser.optionCards[1].setHovered(true)
            try write(defaultBrowser, "5-default-hover-\(suffix)")
            let finish = Self.makeController(step: .finish)
            try write(finish, "6-finish-\(suffix)")
        }
        NSApplication.shared.appearance = nil
    }
}
