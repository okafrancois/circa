import AppKit
@testable import BrowserCore
import BrowserShell
import Foundation
import Testing
@testable import Orbit
import BrowserEngine
import WebKitEngine

private let reference = CGSize(width: 1024, height: 640)

private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool { abs(a - b) <= tolerance }

private func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.01) -> Bool {
    close(a.minX, b.minX, tolerance) && close(a.minY, b.minY, tolerance)
        && close(a.width, b.width, tolerance) && close(a.height, b.height, tolerance)
}

/// Fourth-order Runge–Kutta reference for x'' = −k·x − c·x'.
private func integrate(_ spring: OrbitTokens.Spring, x0: Double, v0: Double, until time: Double) -> (Double, Double) {
    let k = Double(spring.stiffness), c = Double(spring.damping)
    var x = x0, v = v0
    let steps = 20_000
    let h = time / Double(steps)
    func a(_ x: Double, _ v: Double) -> Double { -k * x - c * v }
    for _ in 0..<steps {
        let k1x = v, k1v = a(x, v)
        let k2x = v + h / 2 * k1v, k2v = a(x + h / 2 * k1x, v + h / 2 * k1v)
        let k3x = v + h / 2 * k2v, k3v = a(x + h / 2 * k2x, v + h / 2 * k2v)
        let k4x = v + h * k3v, k4v = a(x + h * k3x, v + h * k3v)
        x += h / 6 * (k1x + 2 * k2x + 2 * k3x + k4x)
        v += h / 6 * (k1v + 2 * k2v + 2 * k3v + k4v)
    }
    return (x, v)
}

@MainActor
private final class ManualTimer: OrbitCancellable {
    let fireTime: TimeInterval
    var action: (@MainActor () -> Void)?
    init(_ fireTime: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        self.fireTime = fireTime
        self.action = action
    }
    func cancel() { action = nil }
}

@MainActor
private final class ManualClock {
    var now: TimeInterval = 0
    var timers: [ManualTimer] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any OrbitCancellable {
        let timer = ManualTimer(now + delay, action)
        timers.append(timer)
        return timer
    }

    func advance(by delta: TimeInterval) {
        now += delta
        for timer in timers where timer.fireTime <= now + 1e-9 {
            let action = timer.action
            timer.action = nil
            action?()
        }
    }
}

// MARK: - Tokens and motion

extension NativeWebKitTests {
@Suite("Theme tokens and motion")
@MainActor
struct ThemeMotionTests {
    @Test("The Space-switch spring converts to Core Animation coefficients")
    func spaceSwitchSpringConversion() {
        let spring = OrbitTokens.Motion.spaceSwitchSidebar
        #expect(spring.response == 0.4 && spring.dampingFraction == 1)
        #expect(close(spring.stiffness, 246.7401, 0.0001))
        #expect(close(spring.damping, 31.41593, 0.0001))
        let animation = spring.animation(keyPath: "transform.translation.x")
        #expect(animation.mass == 1 && close(animation.stiffness, spring.stiffness) && close(animation.damping, spring.damping))
        // Nominal spring time; the animation driver advances faster than wall time.
        #expect(spring.settlingDuration > 0.58 && spring.settlingDuration < 0.60)
    }

    @Test("The analytic spring matches a numerical integration in every damping regime", arguments: [
        OrbitTokens.Spring(response: 0.22, dampingFraction: 0.96),
        OrbitTokens.Spring(response: 0.30, dampingFraction: 1.0),
        OrbitTokens.Spring(response: 0.35, dampingFraction: 0.85),
        OrbitTokens.Spring(response: 0.25, dampingFraction: 1.3)
    ])
    func analyticSpring(spring: OrbitTokens.Spring) {
        for time in [0.0, 0.03, 0.08, 0.15, 0.4] {
            let exact = spring.state(after: time, displacement: 228, velocity: -900)
            let reference = integrate(spring, x0: 228, v0: -900, until: time)
            #expect(abs(exact.displacement - reference.0) < 0.01, "x at \(time)")
            #expect(abs(exact.velocity - reference.1) < 0.1, "v at \(time)")
        }
    }

    @Test("Sidebar timing follows Orbit native animation groups and the springyFast hover preset")
    func sidebarSpringBounds() {
        func overshoot(_ spring: OrbitTokens.Spring) -> Double {
            var time = 0.0, deepest = 0.0
            while time < 1 {
                deepest = min(deepest, spring.state(after: time, displacement: 1, velocity: 0).displacement)
                time += 0.0005
            }
            return -deepest
        }
        let toggle = OrbitAnimationTiming.sidebar
        #expect(toggle.duration == 0.08)
        #expect(toggle.progress(after: 0.08) == 1)
        #expect(toggle.progress(after: 0.04) > 0.5)
        let reveal = OrbitTokens.Motion.sidebarHoverReveal
        #expect(reveal.response == 0.18 && reveal.dampingFraction == 0.8)
        #expect(overshoot(reveal) > 0.001 && overshoot(reveal) < 0.03)
        #expect(OrbitTokens.Motion.sidebarHoverExit == reveal)
        #expect(OrbitTokens.Motion.sidebarHoverDwell == 0.10 && OrbitTokens.Motion.sidebarHoverLeaveDelay == 0.05)
    }

    @Test("Tab effects share the native 120 ms group; ordinary Split layout and theme mode changes stay immediate")
    func tabMotion() {
        #expect(OrbitAnimationTiming.tabList.duration == 0.12)
        #expect(OrbitAnimationTiming.tabList.progress(after: 0.12) == 1)
        #expect(OrbitTokens.Motion.peekPresent == OrbitTokens.Spring(response: 0.255, dampingFraction: 0.86))
        #expect(OrbitTokens.Motion.splitLayoutIsInstant && OrbitTokens.Motion.themeModeSwitchIsInstant)
    }

    @Test("An interrupted spring keeps its value and velocity when retargeted")
    func interruptionIsContinuous() {
        var now: CFTimeInterval = 10
        let animator = OrbitSpringAnimator(value: 1)
        animator.clock = { now }
        animator.beginSegment(to: 0, spring: OrbitTokens.Motion.sidebarToggle)
        // ⌘S settles in ≈80 ms: interrupt it a third of the way.
        now += 0.025
        animator.advance(to: now)
        let before = animator.currentState(at: now)
        #expect(before.value > 0.05 && before.value < 0.95 && before.velocity < 0)
        animator.beginSegment(to: 1, spring: OrbitTokens.Motion.sidebarToggle)
        let after = animator.currentState(at: now)
        #expect(close(CGFloat(after.value), CGFloat(before.value), 1e-9))
        #expect(close(CGFloat(after.velocity), CGFloat(before.velocity), 1e-6))
        var settled = false
        animator.onSettle = { settled = true }
        now += 2
        animator.advance(to: now)
        #expect(settled && animator.value == 1 && !animator.isAnimating)
    }

    @Test("Without a visible driver view the animator jumps to its target")
    func hiddenDriverJumps() {
        let animator = OrbitSpringAnimator(value: 1)
        var settled = false
        animator.onSettle = { settled = true }
        animator.animate(to: 0, spring: OrbitTokens.Motion.sidebarToggle, in: NSView())
        #expect(animator.value == 0 && settled && !animator.isAnimating)
    }

    @Test("Reduce motion replaces springs by cross-fades; invisible changes jump")
    func motionPolicy() {
        #expect(OrbitMotionStyle.resolve(animated: true, canAnimate: true, reducedMotion: false) == .spring)
        #expect(OrbitMotionStyle.resolve(animated: true, canAnimate: true, reducedMotion: true) == .crossfade)
        #expect(OrbitMotionStyle.resolve(animated: true, canAnimate: false, reducedMotion: false) == .jump)
        #expect(OrbitMotionStyle.resolve(animated: false, canAnimate: true, reducedMotion: true) == .jump)
        let saved = OrbitMotionPreferences.overrideReducedMotion
        defer { OrbitMotionPreferences.overrideReducedMotion = saved }
        OrbitMotionPreferences.overrideReducedMotion = true
        #expect(OrbitTokens.Motion.prefersReducedMotion)
        OrbitMotionPreferences.overrideReducedMotion = false
        #expect(!OrbitTokens.Motion.prefersReducedMotion)
        #expect(OrbitTokens.Motion.reducedMotionCrossfade == 0.12)
    }

    @Test("CASpringAnimation velocities are normalised by the travelled distance")
    func normalizedVelocity() {
        #expect(OrbitTransitions.normalizedVelocity(-456, from: 228, to: 0) == 2)
        #expect(OrbitTransitions.normalizedVelocity(10, from: 5, to: 5) == 0)
    }
}
}

// MARK: - Appearance and themes

extension NativeWebKitTests {
@Suite("Appearance and Space themes")
@MainActor
struct ThemeAppearanceTests {
    @Test("Theme modes and the validation override resolve the window appearance")
    func windowAppearance() {
        #expect(OrbitAppearance.windowAppearance(for: .light, override: nil)?.name == .aqua)
        #expect(OrbitAppearance.windowAppearance(for: .dark, override: nil)?.name == .darkAqua)
        #expect(OrbitAppearance.windowAppearance(for: .automatic, override: nil) == nil)
        #expect(OrbitAppearance.windowAppearance(for: .light, override: .darkAqua)?.name == .darkAqua)
        #expect(OrbitAppearance.override(in: ["Orbit", "--appearance", "dark"]) == .darkAqua)
        #expect(OrbitAppearance.override(in: ["Orbit", "--appearance", "light"]) == .aqua)
        #expect(OrbitAppearance.override(in: ["Orbit", "--appearance"]) == nil)
        #expect(OrbitAppearance.override(in: ["Orbit", "--appearance", "sepia"]) == nil)
    }

    @Test("Dynamic tokens resolve to their exact light and dark values")
    func dynamicColours() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        func rgb(_ colour: NSColor, _ appearance: NSAppearance) -> [CGFloat] {
            let c = colour.resolved(for: appearance)
            return [c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255]
        }
        func matches(_ values: [CGFloat], _ hex: UInt32) -> Bool {
            zip(values, [CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF)]).allSatisfy { close($0, $1, 0.6) }
        }
        // : round 2 values.
        #expect(matches(rgb(OrbitTokens.Color.Surface.windowDefault, light), 0xE6E0ED))
        #expect(matches(rgb(OrbitTokens.Color.Surface.windowDefault, dark), 0x2D2438))
        #expect(matches(rgb(OrbitTokens.Color.Surface.commandBar, light), 0xF9F9F9))
        #expect(matches(rgb(OrbitTokens.Color.Surface.commandBar, dark), 0x313131))
        #expect(close(OrbitTokens.Color.Surface.contentEmptyPage.resolved(for: light).alphaComponent, 0.70))
        #expect(close(OrbitTokens.Color.Surface.contentEmptyPage.resolved(for: dark).alphaComponent, 0.10))
        #expect(matches(rgb(OrbitTokens.Color.State.tabCurrent, light), 0xF6F6F6))
        #expect(close(OrbitTokens.Color.State.tabCurrent.resolved(for: light).alphaComponent, 0.88))
        #expect(close(OrbitTokens.Color.State.tabCurrent.resolved(for: dark).alphaComponent, 0.20))
        #expect(close(OrbitTokens.Color.State.tabPressed.resolved(for: light).alphaComponent, 0.10))
        #expect(close(OrbitTokens.Color.State.tabPressed.resolved(for: dark).alphaComponent, 0.10))
        #expect(close(OrbitTokens.Color.State.rowCloseButtonHover.resolved(for: light).alphaComponent, 0.07))
        #expect(close(OrbitTokens.Color.State.rowCloseButtonHover.resolved(for: dark).alphaComponent, 0.075))
        #expect(close(OrbitTokens.Color.ShadowColor.tabSelected.resolved(for: dark).alphaComponent, 0))
        #expect(close(OrbitTokens.Color.ShadowColor.contentCard.resolved(for: dark).alphaComponent, 0.24))
        #expect(close(OrbitTokens.Color.ShadowColor.commandBar.resolved(for: light).alphaComponent, 0.50))
        #expect(close(OrbitTokens.Color.Text.sidebarLabel.resolved(for: light).alphaComponent, 0.50))
        #expect(close(OrbitTokens.Color.Text.sidebarLabel.resolved(for: dark).alphaComponent, 0.50))
        #expect(close(OrbitTokens.Color.Text.sidebarNewTab.resolved(for: light).alphaComponent, 0.45))
        #expect(matches(rgb(OrbitTokens.Color.Text.sidebarTitle, light), 0x080C4E))
        #expect(matches(rgb(OrbitTokens.Color.Text.sidebarTitle, dark), 0xDEDFFF))
        #expect(close(OrbitTokens.Color.Text.sidebarTitle.resolved(for: light).alphaComponent, 1))
    }

    @Test("Stops normalise to three colours with the exact midpoint of a two-stop gradient")
    func normalizedStops() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        #expect(OrbitThemeGradient.normalizedStops(OrbitTokens.SpaceTheme.default.stops, appearance: appearance).count == 3)
        let stops = OrbitThemeGradient.normalizedStops([.black, .white], appearance: appearance)
        let middle = try #require(NSColor(cgColor: stops[1])?.usingColorSpace(.sRGB))
        #expect(stops.count == 3 && close(middle.redComponent, 0.5, 0.01))
        #expect(OrbitThemeGradient.normalizedStops(OrbitTokens.SpaceTheme.amberCoral.stops, appearance: appearance).count == 3)
    }

    @Test("The default Space uses its declared accent; themed Spaces derive theirs from their hue")
    func accents() throws {
        var defaultColors = OrbitSpaceThemes.accent(for: .default)
        defaultColors.contrastTheme = nil // The provenance is not a measured colour role.
        #expect(defaultColors.sidebarText == defaultColors.icon)
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let selection = OrbitTokens.ThemeAccent.defaultSpace.selection.resolved(for: light)
        #expect(close(selection.redComponent * 255, 0x8F, 0.6) && close(selection.blueComponent * 255, 0xFF, 0.6))
        let menuDark = OrbitTokens.ThemeAccent.defaultSpace.menuSurface.resolved(for: dark)
        #expect(close(menuDark.blueComponent * 255, 0x27, 0.6))
        let lime = OrbitSpaceThemes.accent(for: .limeCitrus)
        #expect(lime != .defaultSpace && lime != .defaultPurple)
        let derivedText = try #require(lime.sidebarText.resolved(for: light).usingColorSpace(.sRGB))
        #expect(derivedText == OrbitThemeForeground.color(on: OrbitThemeGradient.representativeColor(.limeCitrus, appearance: light)))
        let strong = try #require(lime.strong.usingColorSpace(.sRGB))
        #expect(strong.hueComponent > 0.1 && strong.hueComponent < 0.3)
    }

    @Test("Every Space uses the default fill until the model stores themes; the preview flag cycles examples")
    func themeResolution() {
        let profile = ProfileID()
        let spaces = (0..<3).map { BrowserSpace(id: SpaceID(), profileID: profile, name: "Synthetic \($0)") }
        let catalog = BrowserCatalogSnapshot(profiles: [BrowserProfile(id: profile, name: "Synthetic")], spaces: spaces)
        #expect(OrbitSpaceThemes.theme(forSpace: spaces[2].id, in: catalog) == (OrbitSpaceThemes.previewFlag ? .lavender : .default))
        #expect(OrbitSpaceThemes.theme(forSpace: SpaceID(), in: catalog) == .default)
        #expect(OrbitSpaceThemes.defaultTheme(at: 1, preview: true) == .amberCoral)
        #expect(OrbitSpaceThemes.defaultTheme(at: 5, preview: true) == .default)
        #expect(OrbitSpaceThemes.defaultTheme(at: 1, preview: false) == .default)
    }

    @Test("The window fill runs from the top-left stop to the bottom-right stop")
    func gradientOrientation() throws {
        let view = OrbitThemeFillView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.apply(.amberCoral)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        view.layer?.render(in: context.cgContext)
        // Bitmap rows run top to bottom: (0, 0) is the top-left pixel.
        let topLeft = try #require(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        let bottomRight = try #require(bitmap.colorAt(x: 198, y: 98)?.usingColorSpace(.sRGB))
        // amberCoral: #E4AA3B → #F17C5C → #F2606B.
        #expect(close(topLeft.greenComponent * 255, 0xAA, 8) && close(topLeft.blueComponent * 255, 0x3B, 8))
        #expect(close(bottomRight.greenComponent * 255, 0x60, 8) && close(bottomRight.blueComponent * 255, 0x6B, 8))
    }
}
}

// MARK: - Geometry

@Suite("Window and sidebar geometry")
struct ShellGeometryTests {
    @Test("Pinned sidebar at 1024 × 640: column 228, card inset 10, radius 6, window buttons at x 20 + n × the system pitch, y 24")
    func dockedReference() {
        let geometry = OrbitShellGeometry.resolve(.init(contentSize: reference))
        #expect(close(geometry.sidebarFrame, CGRect(x: 0, y: 0, width: 228, height: 640)))
        #expect(close(geometry.cardFrame, CGRect(x: 228, y: 10, width: 786, height: 620)))
        #expect(geometry.cardRadius == 6 && geometry.floatingChrome == 0)
        #expect(geometry.trafficLightCenters == [CGPoint(x: 20, y: 24), CGPoint(x: 43, y: 24), CGPoint(x: 66, y: 24)])
        let older = OrbitShellGeometry.resolve(.init(contentSize: reference, trafficLightPitch: 20))
        #expect(older.trafficLightCenters == [CGPoint(x: 20, y: 24), CGPoint(x: 40, y: 24), CGPoint(x: 60, y: 24)])
        #expect(geometry.trafficLightsVisible && geometry.isSidebarOnScreen)
    }

    @Test("Hidden sidebar: card inset 10 on every side, window buttons hidden; full screen goes edge to edge")
    func hidden() {
        let windowed = OrbitShellGeometry.resolve(.init(contentSize: reference, dockProgress: 0))
        #expect(close(windowed.cardFrame, CGRect(x: 10, y: 10, width: 1004, height: 620)))
        #expect(windowed.cardRadius == 6 && !windowed.trafficLightsVisible && !windowed.isSidebarOnScreen)
        #expect(windowed.sidebarFrame.maxX <= 0)
        let fullScreen = OrbitShellGeometry.resolve(.init(contentSize: reference, dockProgress: 0, isFullScreen: true))
        #expect(close(fullScreen.cardFrame, CGRect(origin: .zero, size: reference)))
        #expect(fullScreen.cardRadius == 0)
        let fullScreenDocked = OrbitShellGeometry.resolve(.init(contentSize: reference, isFullScreen: true))
        #expect(close(fullScreenDocked.cardFrame, CGRect(x: 228, y: 10, width: 786, height: 620)))
    }

    @Test("Mid-toggle frames interpolate monotonically between pinned and hidden")
    func toggleInterpolation() {
        var previous = OrbitShellGeometry.resolve(.init(contentSize: reference, dockProgress: 0))
        for step in 1...10 {
            let current = OrbitShellGeometry.resolve(.init(contentSize: reference, dockProgress: CGFloat(step) / 10))
            #expect(current.sidebarFrame.minX > previous.sidebarFrame.minX)
            #expect(current.cardFrame.minX > previous.cardFrame.minX)
            #expect(close(current.cardFrame.maxX, 1014))
            #expect(close(current.cardFrame.minX, current.dockedColumnMinX + 228 + current.cardGap))
            previous = current
        }
    }

    @Test("The hover-revealed sidebar floats inset 5 above the hidden-layout card, radius 12, and docks continuously")
    func floating() {
        let hidden = OrbitShellGeometry.resolve(.init(contentSize: reference, dockProgress: 0))
        let floating = OrbitShellGeometry.resolve(.init(contentSize: reference, dockProgress: 0, floatProgress: 1))
        #expect(close(floating.sidebarFrame, CGRect(x: 5, y: 5, width: 228, height: 630)))
        #expect(close(floating.cardFrame, hidden.cardFrame))
        #expect(floating.floatingChrome == 1 && floating.floatingRadius == 12)
        #expect(floating.trafficLightCenters[0] == CGPoint(x: 25, y: 29) && floating.trafficLightsVisible)
        // Travel = width + 5 + shadow blur 8: fully offscreen at 0.
        #expect(OrbitTokens.Shadow.floatingSidebar.blur == 8 && OrbitTokens.Shadow.floatingSidebar.offsetY == 0)
        let start = OrbitShellGeometry.resolve(.init(contentSize: reference, dockProgress: 0, floatProgress: 0.0001))
        #expect(start.sidebarFrame.maxX <= 0.1 && !start.trafficLightsVisible)
        let docked = OrbitShellGeometry.resolve(.init(contentSize: reference, dockProgress: 1, floatProgress: 1))
        #expect(close(docked.sidebarFrame, CGRect(x: 0, y: 0, width: 228, height: 640)) && docked.floatingChrome == 0)
        let half = OrbitShellGeometry.resolve(.init(contentSize: reference, dockProgress: 0.5, floatProgress: 1))
        #expect(close(half.sidebarFrame.minX, 2.5) && close(half.floatingChrome, 0.5))
    }

    @Test("Resizing tracks the pointer between 164 and 500 and collapses once the pointer passes 82 pt from the edge")
    func resizeRule() {
        #expect(OrbitShellGeometry.resize(proposedWidth: 300) == .width(300))
        #expect(OrbitShellGeometry.resize(proposedWidth: 120) == .width(164))
        #expect(OrbitShellGeometry.resize(proposedWidth: 650) == .width(500))
        #expect(OrbitShellGeometry.resize(proposedWidth: 83) == .width(164))
        #expect(OrbitShellGeometry.resize(proposedWidth: 81) == .collapse)
        // The pointer decides, not the clamped width.
        #expect(OrbitShellGeometry.resize(proposedWidth: 170, pointerX: 81) == .collapse)
        #expect(OrbitShellGeometry.resize(proposedWidth: 100, pointerX: 100) == .width(164))
        #expect(OrbitTokens.Motion.sidebarCollapseIsInstant)
    }

    @Test("Sidebar anatomy matches the specimen at 228 × 640 (one Favorites row, 4 pinned, 3 Today, 3 Spaces)")
    func sidebarReference() {
        let geometry = OrbitSidebarGeometry.resolve(.init(height: 640, favoriteCount: 2, pinnedRowCount: 4, todayRowCount: 3, spaceCount: 3))
        #expect(geometry.toolbarCenterY == 24)
        #expect([geometry.sidebarToggleCenterX, geometry.backCenterX, geometry.forwardCenterX, geometry.reloadCenterX] == [93.25, 137.75, 171.75, 206])
        #expect(!geometry.toolbar.isCompact && geometry.toolbar.overflowCenterX == nil)
        #expect(geometry.toolbarHitWidth == 28)
        #expect(geometry.addressFrame == CGRect(x: 8, y: 46, width: 212, height: 36))
        #expect(geometry.favoritesFrame == CGRect(x: 8, y: 90, width: 212, height: 47))
        #expect(geometry.favoriteColumns == 2)
        #expect(OrbitTokens.Metrics.Sidebar.favoriteColumns(count: 4, sidebarWidth: 237) == 4)
        // Orbit caps the grid at 4 per row, however wide the sidebar (10 → 4 + 4 + 2).
        #expect(OrbitTokens.Metrics.Sidebar.favoriteColumns(count: 10, sidebarWidth: 400) == 4)
        #expect(OrbitTokens.Metrics.Sidebar.favoriteColumns(count: 5, sidebarWidth: 400) == 3)
        #expect(OrbitTokens.Metrics.Sidebar.favoriteColumns(count: 4, sidebarWidth: 243) == 4)
        #expect(OrbitTokens.Metrics.Sidebar.favoriteColumns(count: 4, sidebarWidth: 203) == 2)
        #expect(OrbitTokens.Metrics.Sidebar.favoriteMinimumTileWidth == 45)
        let top = geometry.pageFrame.minY
        #expect(top == 137)
        #expect(top + geometry.spaceTitleCenterY == 164.5)
        #expect(geometry.pinnedRowCenters.map { top + $0 } == [200.5, 241.5, 282.5, 323.5])
        #expect(top + geometry.separatorCenterY == 352.5 && geometry.isSeparatorVisible)
        #expect(top + geometry.newTabCenterY == 381.75)
        #expect(geometry.todayRowCenters.map { top + $0 } == [422.75, 463.75, 504.75])
        #expect(geometry.spaceTitleOriginX == 16)
        #expect(geometry.rowFrame(centerY: 0) == CGRect(x: 8, y: -18, width: 212, height: 36))
        #expect(geometry.footerFrame.minY + geometry.footerCenterY == 615)
        #expect(geometry.libraryCenterX == 24 && geometry.plusCenterX == 204)
        #expect(geometry.spaceCenterXs == [80, 114, 148])
        #expect(geometry.pageFrame.maxY == geometry.footerFrame.minY)
    }

    @Test("Without pinned rows the separator sits 27.25 below the title and only shows with Today rows")
    func emptySections() {
        let geometry = OrbitSidebarGeometry.resolve(.init(height: 640, todayRowCount: 1))
        #expect(geometry.favoritesFrame.height == 0 && geometry.pageFrame.minY == 82)
        #expect(geometry.spaceTitleCenterY == 27.5)
        #expect(geometry.separatorCenterY == 27.5 + 27.25 && geometry.isSeparatorVisible)
        #expect(geometry.newTabCenterY == geometry.separatorCenterY + 29.25)
        #expect(geometry.todayRowCenters == [geometry.newTabCenterY + 41])
        // Today empty and no pinned row: no separator, New Tab 40.5 below the title.
        let empty = OrbitSidebarGeometry.resolve(.init(height: 640))
        #expect(!empty.isSeparatorVisible && empty.newTabCenterY == 27.5 + 40.5 && empty.todayRowCenters.isEmpty)
        // Pinned rows with an empty Today were not captured: the separator stays.
        let pinnedOnly = OrbitSidebarGeometry.resolve(.init(height: 640, pinnedRowCount: 2))
        #expect(pinnedOnly.isSeparatorVisible && pinnedOnly.separatorCenterY == pinnedOnly.pinnedRowCenters[1] + 29)
        // Space title x 16 without an icon, 44 with one.
        #expect(empty.spaceTitleOriginX == 16)
        #expect(OrbitSidebarGeometry.resolve(.init(height: 640, spaceHasIcon: true)).spaceTitleOriginX == 44)
        #expect(OrbitSidebarGeometry.PageRhythm.resolve(pinnedRowCount: 0, todayRowCount: 0).newTabCenterY == 68)
    }

    @Test("Section seams place Favorites tiles and pinned rows on the measured grid")
    func sectionSeams() {
        let geometry = OrbitSidebarGeometry.resolve(.init(height: 640, favoriteCount: 2, pinnedRowCount: 4))
        #expect(geometry.favoriteTileFrame(index: 0) == CGRect(x: 0, y: 0, width: 102, height: 47))
        #expect(geometry.favoriteTileFrame(index: 1) == CGRect(x: 110, y: 0, width: 102, height: 47))
        // Specimen rows 200.5 … 323.5 in window coordinates, inside the pinned container.
        let top = geometry.pageFrame.minY + geometry.spaceTitleCenterY + 36 - 18
        #expect((0..<4).map { top + geometry.pinnedRowFrame(index: $0).midY } == [200.5, 241.5, 282.5, 323.5])
        #expect(geometry.pinnedRowFrame(index: 0).minX == 8 && geometry.pinnedRowFrame(index: 0).width == 212)
        #expect(OrbitSidebarGeometry.contentIndent(depth: 1) == 13 && OrbitSidebarGeometry.contentIndent(depth: 0) == 0)
        let three = OrbitSidebarGeometry.resolve(.init(height: 640, favoriteCount: 5))
        #expect(three.favoriteColumns == 3 && three.favoriteTileFrame(index: 4).minY == 55)
    }

    @Test("The toolbar has two states: full row anchored right from 224, compact row below",
          arguments: [164.0, 180.0, 206.0, 223.0, 224.0, 228.0, 243.0, 334.0, 500.0])
    func toolbarAtWidths(width: Double) {
        let w = CGFloat(width)
        let toolbar = OrbitSidebarGeometry.resolve(.init(width: w, height: 640)).toolbar
        // Window buttons end at 66 + 6 with the fallback pitch 23.
        let lightsEnd: CGFloat = 20 + 2 * 23 + 6
        if w >= 224 {
            #expect(!toolbar.isCompact && toolbar.overflowCenterX == nil)
            #expect(toolbar.sidebarToggleCenterX == 93.25)
            #expect([toolbar.backCenterX, toolbar.forwardCenterX, toolbar.reloadCenterX] == [w - 90.25, w - 56.25, w - 22])
            let toggle = toolbar.sidebarToggleCenterX ?? 0
            #expect(toggle - 14 > lightsEnd && toolbar.backCenterX - 14 >= toggle + 14)
            #expect((toolbar.reloadCenterX ?? 0) + toolbar.hitWidth / 2 <= w - 8)
        } else {
            #expect(toolbar.isCompact && toolbar.sidebarToggleCenterX == nil && toolbar.reloadCenterX == nil)
            #expect([toolbar.backCenterX, toolbar.forwardCenterX, toolbar.overflowCenterX] == [w - 76, w - 48, w - 20])
            #expect(toolbar.backCenterX - toolbar.hitWidth / 2 >= lightsEnd)
        }
        #expect(toolbar.hitWidth <= toolbar.forwardCenterX - toolbar.backCenterX + 0.001)
    }

    @Test("The toggle follows the system pitch and moves to x 28.6 in full screen")
    func toolbarPitchAndFullScreen() {
        #expect(OrbitSidebarGeometry.Toolbar.resolve(width: 228, trafficLightPitch: 20).sidebarToggleCenterX == 87.25)
        #expect(OrbitSidebarGeometry.Toolbar.resolve(width: 228, trafficLightPitch: 23).sidebarToggleCenterX == 93.25)
        let fullScreen = OrbitSidebarGeometry.Toolbar.resolve(width: 228, isFullScreen: true)
        #expect(fullScreen.sidebarToggleCenterX == 28.6 && fullScreen.backCenterX == 228 - 90.25)
    }

    @Test("Footer Space icons compress instead of overlapping the side buttons")
    func crowdedFooter() {
        let geometry = OrbitSidebarGeometry.resolve(.init(height: 640, spaceCount: 12))
        let first = geometry.spaceCenterXs.first ?? 0, last = geometry.spaceCenterXs.last ?? 0
        #expect(first - 14 >= geometry.libraryCenterX && last + 14 <= geometry.plusCenterX)
        #expect(close(first + last, 228))
    }
}

// MARK: - Hover reveal

extension NativeWebKitTests {
@Suite("Sidebar hover reveal")
@MainActor
struct HoverRevealTests {
    private func makeReveal() -> (OrbitSidebarHoverReveal, ManualClock, () -> [Bool]) {
        let reveal = OrbitSidebarHoverReveal()
        let clock = ManualClock()
        var events: [Bool] = []
        reveal.schedule = { clock.schedule($0, $1) }
        reveal.onRevealChange = { events.append($0) }
        reveal.setEnabled(true)
        return (reveal, clock, { events })
    }

    @Test("Resting 100 ms in the edge band reveals; crossing it does not")
    func dwell() {
        let (reveal, clock, events) = makeReveal()
        reveal.pointerEnteredEdge()
        clock.advance(by: 0.05)
        reveal.pointerExitedEdge()
        clock.advance(by: 0.2)
        #expect(events().isEmpty && reveal.phase == .idle)
        reveal.pointerEnteredEdge()
        clock.advance(by: 0.099)
        #expect(events().isEmpty)
        clock.advance(by: 0.002)
        #expect(events() == [true] && reveal.phase == .revealed)
    }

    @Test("Leaving waits 50 ms and coming back cancels the dismissal")
    func leaveDelay() {
        let (reveal, clock, events) = makeReveal()
        reveal.pointerEnteredEdge()
        clock.advance(by: 0.1)
        reveal.pointerExitedPanel()
        clock.advance(by: 0.03)
        reveal.pointerEnteredPanel()
        clock.advance(by: 1)
        #expect(events() == [true] && reveal.phase == .revealed)
        reveal.pointerExitedPanel()
        clock.advance(by: 0.049)
        #expect(events() == [true])
        clock.advance(by: 0.002)
        #expect(events() == [true, false] && reveal.phase == .idle)
    }

    @Test("Menus and editing hold the sidebar open until they end")
    func holds() {
        let (reveal, clock, events) = makeReveal()
        var held = true
        reveal.isHeld = { held }
        reveal.isPointerInside = { false }
        reveal.pointerEnteredEdge()
        clock.advance(by: 0.1)
        reveal.pointerExitedPanel()
        clock.advance(by: 1)
        #expect(events() == [true])
        held = false
        reveal.holdDidChange()
        clock.advance(by: 0.3)
        #expect(events() == [true, false])
    }

    @Test("A disabled reveal ignores the edge until it is enabled again")
    func disabled() {
        let (reveal, clock, events) = makeReveal()
        reveal.setEnabled(false)
        reveal.pointerEnteredEdge()
        clock.advance(by: 1)
        #expect(events().isEmpty && reveal.phase == .disabled)
        reveal.setEnabled(true)
        reveal.pointerEnteredEdge()
        reveal.setEnabled(false)
        clock.advance(by: 1)
        #expect(events().isEmpty)
    }
}
}

// MARK: - Live window

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeThemeShellTests {
    private func trafficLightCenters(_ window: NSWindow) throws -> [CGPoint] {
        let content = try #require(window.contentView)
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            guard let button = window.standardWindowButton(type) else { return nil }
            let frame = button.convert(button.bounds, to: nil)
            return CGPoint(x: frame.midX, y: content.bounds.height - frame.midY)
        }
    }

    @Test("A new window has Orbit's frame: transparent full-size title bar, Space fill, card and window buttons in place")
    func windowAnatomy() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView as? OrbitWindowRootView)
        window.setContentSize(reference)
        root.layoutSubtreeIfNeeded()
        #expect(window.styleMask.contains(.fullSizeContentView) && window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden && window.minSize == NSSize(width: 600, height: 400))
        #expect(controller.sidebar.frame.width == 228)
        let card = controller.contentCard.convert(controller.contentCard.bounds, to: root)
        #expect(close(card, CGRect(x: 228, y: 10, width: 786, height: 620)))
        #expect(controller.contentCard.cornerRadius == 6)
        let centers = try trafficLightCenters(window)
        #expect(centers.count == 3)
        let pitch = controller.windowShell.trafficLightPitch
        #expect(pitch >= 18 && pitch <= 30)
        for (index, center) in centers.enumerated() {
            #expect(close(center.x, 20 + CGFloat(index) * pitch, 0.5) && close(center.y, 24, 0.5), "window button at \(center)")
        }
        #expect(root.subviews.first is OrbitThemeFillView)
        #expect(controller.windowShell.theme == OrbitSpaceThemes.theme(forSpace: controller.session.snapshot?.activeSpaceID,
                                                                     in: controller.session.catalog))
        let address = controller.sidebar.addressContainer.convert(controller.sidebar.addressContainer.bounds, to: controller.sidebar)
        #expect(address == CGRect(x: 8, y: 46, width: 212, height: 36))
        let toolbar = controller.sidebar.navigationContainer.buttons.map { $0.convert($0.bounds, to: controller.sidebar).midX }
        #expect(toolbar == [20 + 2 * pitch + 27.25, 137.75, 171.75, 206])
        #expect(controller.sidebar.navigationContainer.buttons.allSatisfy { $0.frame.midY == 24 && !$0.isHidden })
        #expect(controller.sidebar.navigationContainer.overflowButton?.isHidden == true)
        // Orbit's interface strings are English whatever the system language (UX-LOCALIZATION).
        #expect(controller.backButton.accessibilityLabel() == "Back" && controller.reloadButton.accessibilityLabel() == "Reload")
        #expect(!window.isVisible)
    }

    @Test("⌘S hides the sidebar and its window buttons, the card takes the window with a 10 pt inset, and back")
    func toggleSidebarGeometry() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        window.setContentSize(reference)
        controller.toggleSidebar()
        await controller.session.waitForPendingCommands()
        root.layoutSubtreeIfNeeded()
        #expect(!controller.isSidebarShown && controller.sidebar.isHidden)
        #expect(close(controller.contentCard.convert(controller.contentCard.bounds, to: root), CGRect(x: 10, y: 10, width: 1004, height: 620)))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(controller.windowShell.hoverReveal.phase == .idle)
        controller.toggleSidebar()
        await controller.session.waitForPendingCommands()
        root.layoutSubtreeIfNeeded()
        #expect(controller.isSidebarShown && !controller.sidebar.isHidden)
        #expect(close(controller.contentCard.convert(controller.contentCard.bounds, to: root), CGRect(x: 228, y: 10, width: 786, height: 620)))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(controller.windowShell.hoverReveal.phase == .disabled)
    }

    @Test("The hover-revealed sidebar floats over the page with its own fill and docks on ⌘S")
    func floatingSidebar() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        window.setContentSize(reference)
        controller.toggleSidebar()
        await controller.session.waitForPendingCommands()
        controller.windowShell.setFloating(true, animated: false)
        root.layoutSubtreeIfNeeded()
        #expect(controller.isSidebarFloating && !controller.sidebar.isHidden)
        #expect(close(controller.sidebar.convert(controller.sidebar.bounds, to: root), CGRect(x: 5, y: 5, width: 228, height: 630)))
        #expect(close(controller.contentCard.convert(controller.contentCard.bounds, to: root), CGRect(x: 10, y: 10, width: 1004, height: 620)))
        #expect(!controller.windowShell.floatingBackdrop.isHidden)
        #expect(close(controller.windowShell.floatingBackdrop.frame, CGRect(x: 5, y: 5, width: 228, height: 630)))
        #expect(controller.windowShell.floatingBackdrop.cornerRadius == 12)
        let dim = try #require(controller.windowShell.floatingBackdrop.dimColor.flatMap { NSColor(cgColor: $0) })
        #expect(close(dim.alphaComponent, 0.12, 0.001))
        let centers = try trafficLightCenters(window)
        #expect(close(centers[0].x, 25, 0.5) && close(centers[0].y, 29, 0.5))
        let subviews = root.subviews
        let sidebarIndex = try #require(subviews.firstIndex(of: controller.sidebar))
        let cardIndex = try #require(subviews.firstIndex(of: controller.contentCard))
        let backdropIndex = try #require(subviews.firstIndex(of: controller.windowShell.floatingBackdrop))
        #expect(cardIndex < backdropIndex && backdropIndex < sidebarIndex)
        controller.toggleSidebar()
        await controller.session.waitForPendingCommands()
        root.layoutSubtreeIfNeeded()
        #expect(controller.isSidebarShown && !controller.isSidebarFloating && controller.windowShell.floatingBackdrop.isHidden)
        #expect(close(controller.sidebar.convert(controller.sidebar.bounds, to: root), CGRect(x: 0, y: 0, width: 228, height: 640)))
    }

    @Test("Resizing moves the card with the column; Library downloads preserve the chosen width")
    func resizeAndDownloads() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        window.setContentSize(NSSize(width: 1100, height: 700))
        controller.windowShell.setSidebarWidth(300)
        root.layoutSubtreeIfNeeded()
        #expect(controller.contentCard.convert(controller.contentCard.bounds, to: root).minX == 300)
        #expect(close(controller.windowShell.resizeHandle.frame, CGRect(x: 292, y: 0, width: 8, height: 700)))
        controller.showDownloads()
        await controller.session.waitForPendingCommands()
        root.layoutSubtreeIfNeeded()
        #expect(!controller.sidebar.isHidden && !controller.downloadsPane.isHidden)
        #expect(controller.library.isPresented)
        // Orbit's home page includes the gap beside its inset body.
        #expect(controller.contentCard.convert(controller.contentCard.bounds, to: root).minX == controller.library.view.bounds.width)
        #expect(controller.windowShell.resizeHandle.isHidden)
        controller.hideLibrary()
        root.layoutSubtreeIfNeeded()
        #expect(controller.sidebarWidth.constant == 300 && !controller.sidebar.isHidden)
        #expect(controller.contentCard.convert(controller.contentCard.bounds, to: root).minX == 300)
    }

    @Test("Full screen with the sidebar hidden puts the card edge to edge without corners")
    func fullScreenLayout() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        window.setContentSize(reference)
        // The windows of the suite stay hidden: replay AppKit's full-screen notifications.
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        controller.toggleSidebar()
        await controller.session.waitForPendingCommands()
        root.layoutSubtreeIfNeeded()
        #expect(close(controller.contentCard.convert(controller.contentCard.bounds, to: root), CGRect(origin: .zero, size: reference)))
        #expect(controller.contentCard.cornerRadius == 0)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        root.layoutSubtreeIfNeeded()
        #expect(close(controller.contentCard.convert(controller.contentCard.bounds, to: root), CGRect(x: 10, y: 10, width: 1004, height: 620)))
        #expect(controller.contentCard.cornerRadius == 6)
    }

    @Test("Switching Space swaps the sidebar page and the window theme, and keeps the page projection exact")
    func spaceSwitchTheme() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let saved = OrbitSpaceThemes.resolver
        defer { OrbitSpaceThemes.resolver = saved }
        OrbitSpaceThemes.resolver = { _, index in index == 0 ? .default : .lavender }
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        let first = try #require(controller.session.snapshot?.activeSpaceID)
        #expect(controller.windowShell.theme == .default)
        let profile = try #require(controller.session.catalog?.profiles.first?.id)
        controller.createSpace(name: "Synthetic themed Space", profileID: profile)
        await controller.session.waitForPendingCommands()
        let second = try #require(controller.session.snapshot?.activeSpaceID)
        #expect(second != first)
        #expect(controller.sidebar.page.spaceID == second && !controller.sidebar.isSwitchingSpace)
        #expect(controller.windowShell.theme == .lavender)
        #expect(controller.windowShell.themeFill.theme == .lavender)
        #expect(controller.sidebar.footer.spaceButtons.map(\.isActive) == [false, true])
        // Destination publication retires the explicit pager blend before the normal chrome
        // projection. A stale stored source theme must not flash or start another spring.
        controller.windowShell.applySpaceSwipeBlend(.init(source: .default, destination: .lavender, progress: 1))
        controller.windowShell.apply(theme: .default, animated: false)
        controller.sidebar.spaceSwipe.onThemeProgress?(nil)
        #expect(controller.windowShell.spaceSwipeBlend == nil)
        #expect(controller.windowShell.theme == .lavender)
        #expect(controller.windowShell.themeFill.theme == .lavender)
        controller.activateSpace(first)
        await controller.session.waitForPendingCommands()
        #expect(controller.sidebar.page.spaceID == first && controller.windowShell.theme == .default)
        #expect(controller.sidebar.footer.spaceButtons.map { $0.accessibilityLabel() } == ["Space Personal", "Space Synthetic themed Space"])
    }

    @Test("⌘S reaches the shell through the command registry binding of the THEME lot")
    func sidebarCommandBinding() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { controller, action in controller.performAcceptedCommand(action) })
        OrbitShellCommands.install(in: registry)
        #expect(registry.isImplemented(.showHideSidebar))
        let id = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let controller = try #require(router.windows[id])
        await controller.session.waitForPendingCommands()
        #expect(registry.resolve(BrowserShortcut(key: "s", modifiers: [.command])) == .showHideSidebar)
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        window.setContentSize(reference)
        #expect(registry.dispatch(.showHideSidebar, origin: .keyboard))
        await router.waitForPendingCommands()
        await controller.session.waitForPendingCommands()
        root.layoutSubtreeIfNeeded()
        #expect(!controller.isSidebarShown && controller.windowShell.dockProgress == 0)
        #expect(close(controller.contentCard.convert(controller.contentCard.bounds, to: root), CGRect(x: 10, y: 10, width: 1004, height: 620)))
        #expect(registry.dispatch(.showHideSidebar, origin: .menu))
        await router.waitForPendingCommands()
        await controller.session.waitForPendingCommands()
        #expect(controller.isSidebarShown && controller.windowShell.dockProgress == 1)
    }

    @Test("The site-controls entry point sits at the trailing end of the sidebar address field and follows it")
    func siteControlsInAddressField() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await BrowserEnvironment(engine: SiteSyntheticEngine()).makeWindow()
        // Site actions belong to a committed document, rather than the initial pending tab.
        controller.submitAddress("https://layout.test/")
        await controller.session.waitForPendingCommands()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        window.setContentSize(reference)
        root.layoutSubtreeIfNeeded()
        let field = controller.sidebar.addressContainer
        let arranged = field.controls.arrangedSubviews
        // daily-surfaces-2026-10-27.md and share-notify-2026-10-27.md add trailing hover actions.
        let site = try #require(arranged.first { $0.accessibilityIdentifier() == "site-controls" } as? NSButton)
        #expect(site.accessibilityIdentifier() == "site-controls")
        #expect(arranged.first === controller.addressControl)
        let siteRect = site.convert(site.bounds, to: controller.sidebar)
        let fieldRect = field.convert(field.bounds, to: controller.sidebar)
        #expect(fieldRect == CGRect(x: 8, y: 46, width: 212, height: 36))
        #expect(fieldRect.contains(siteRect) && siteRect.maxX <= fieldRect.maxX - 6 + 0.5)
        #expect(abs(siteRect.midY - fieldRect.midY) <= 0.5)
        // The text field's alignment rect starts at the measured 12 pt inset (x 20 in the sidebar).
        let textField = controller.addressControl
        let alignment = textField.alignmentRect(forFrame: textField.frame)
        let text = try #require(textField.superview).convert(alignment, to: controller.sidebar)
        #expect(text.minX == 20 && text.maxX <= siteRect.minX, "text \(text) site \(siteRect)")
        #expect(siteRect.height >= 24)
        #expect(site.accessibilityLabel() == "Site Controls" || site.image?.accessibilityDescription == "Site Controls")
        #expect(controller.isAddressFieldOnScreen)
        controller.toggleSidebar()
        await controller.session.waitForPendingCommands()
        #expect(!controller.isAddressFieldOnScreen)
        controller.windowShell.setFloating(true, animated: false)
        root.layoutSubtreeIfNeeded()
        #expect(controller.isAddressFieldOnScreen)
        let floating = site.convert(site.bounds, to: root)
        #expect(floating.minX > 5 && floating.maxX < 233)
    }

    @Test("Row presses select on release and the hover close button keeps its accessible label")
    func rowInteraction() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        controller.openTab()
        await controller.session.waitForPendingCommands()
        let rows = controller.sidebar.page.tabRows
        #expect(rows.count == 2)
        let unselected = try #require(rows.first { !$0.item.selected })
        #expect(unselected.closeButton.accessibilityLabel() == "Close \(unselected.item.title)")
        #expect(!unselected.isCloseButtonVisible)
        #expect(unselected.accessibilityPerformPress())
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.selectedOccurrenceID == unselected.item.occurrenceID)
        #expect(controller.sidebar.page.tabRows.first { $0.item.id == unselected.item.id } === unselected)
    }
}

}

extension NativeWebKitTests.NativeThemeShellTests {
    @Test("Library takeover retires a fullscreen hover panel and prevents rearming", arguments: [false, true])
    func libraryRetiresFloatingSidebar(held: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        controller.setSidebarVisible(false, animated: false)
        let shell = controller.windowShell
        let clock = ManualClock()
        shell.hoverReveal.schedule = { clock.schedule($0, $1) }
        shell.isHoverHeld = { held }
        shell.hoverReveal.isPointerInside = { true }
        shell.hoverReveal.pointerEnteredEdge()
        clock.advance(by: 0.2)
        #expect(shell.hoverReveal.isRevealed && shell.isFloatingRevealed)
        shell.setLibraryProgress(0.5)
        root.layoutSubtreeIfNeeded()
        #expect(abs(shell.floatingBackdrop.alphaValue - controller.sidebar.alphaValue) < 0.001)
        shell.setLibraryProgress(1)
        #expect(shell.hoverReveal.phase == .idle)
        #expect(!shell.isFloatingRevealed)
        #expect(shell.hoverTracker.edgeRect == nil && shell.hoverTracker.keepRect == nil)
        #expect(shell.floatingBackdrop.alphaValue == 0)
        shell.hoverReveal.holdDidChange()
        shell.hoverReveal.pointerEnteredEdge()
        clock.advance(by: 0.2)
        #expect(shell.hoverReveal.phase == .idle && !shell.isFloatingRevealed)
        // Closing the Library restores hidden-sidebar eligibility, without a stale hold.
        shell.setLibraryProgress(0)
        #expect(shell.hoverTracker.edgeRect != nil)
        shell.hoverReveal.pointerEnteredEdge()
        clock.advance(by: 0.2)
        #expect(shell.hoverReveal.isRevealed && shell.isFloatingRevealed)
    }

    @Test("Cancelling a Library swipe restores its floating backdrop with the sidebar")
    func libraryCancelledSwipeRestoresFloatingSidebar() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        controller.setSidebarVisible(false, animated: false)
        let shell = controller.windowShell
        shell.setFloating(true, animated: false)
        shell.setLibraryProgress(0.4)
        #expect(abs(shell.floatingBackdrop.alphaValue - controller.sidebar.alphaValue) < 0.001)
        shell.setLibraryProgress(0)
        #expect(shell.isFloatingRevealed)
        #expect(shell.floatingBackdrop.alphaValue == 1 && controller.sidebar.alphaValue == 1)
    }
}

extension NativeWebKitTests.NativeThemeShellTests {
    @Test("The production Library swipe completion releases hover state and session input")
    func librarySwipeCompletionReleasesHoverOwner() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        controller.setSidebarVisible(false, animated: false)
        let shell = controller.windowShell
        let clock = ManualClock()
        shell.hoverReveal.schedule = { clock.schedule($0, $1) }
        shell.hoverReveal.isPointerInside = { true }
        shell.hoverReveal.pointerEnteredEdge()
        clock.advance(by: 0.2)
        #expect(shell.hoverReveal.isRevealed)
        controller.library.swipe.beginOpening?()
        controller.library.swipe.finish?(true, 0)
        #expect(controller.library.isPresented)
        #expect(shell.hoverReveal.phase == .idle && !shell.isFloatingRevealed)
        #expect(shell.floatingBackdrop.alphaValue == 0)
        #expect(shell.floatingBackdrop.hitTest(.zero) == nil)
        controller.hideLibrary()
        controller.openTab(url: URL(string: "https://library-swipe.test/responsive")!)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface?.currentURL?.host == "library-swipe.test")
        window.performClose(nil)
        #expect(controller.session.isClosed)
    }
}
