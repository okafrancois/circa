import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite("UI performance change guards") @MainActor
struct UIPerfGuardsTests {
    /// A pending repaint of the layer-backed grain. `NSView.needsDisplay` stays set for a window
    /// that is never ordered in, so the backing layer's own invalidation is the observable signal.
    private func pendingRepaint(_ view: NSView) -> Bool { view.layer?.needsDisplay() == true }
    private func flush(_ view: NSView) { view.layer?.displayIfNeeded() }

    /// The window is never ordered in.
    private func hosted(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    private func grain(_ appearance: NSAppearance.Name) -> (NSWindow, OrbitPaperGrainView) {
        let view = OrbitPaperGrainView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = hosted(view)
        view.appearance = NSAppearance(named: appearance)
        view.viewDidChangeEffectiveAppearance()
        flush(view)
        return (window, view)
    }

    @Test("Paper grain strength never repaints the tile pattern without a light/dark flip")
    func grainStrengthKeepsPattern() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let (window, view) = grain(name)
            defer { window.close() }
            let current = view.strength
            view.strength = current
            #expect(!pendingRepaint(view))
            for strength: CGFloat in [0.1, 0.45, 0.8, 0] {
                view.strength = strength
                #expect(!pendingRepaint(view))
                let expected = name == .darkAqua ? strength * 0.15 : OrbitPaperGrainView.opacity(for: strength)
                #expect(abs(view.alphaValue - expected) < 0.00001)
            }
        }
    }

    @Test("Paper grain repaints once when the light/dark tile changes")
    func grainAppearanceFlipRepaints() {
        let (window, view) = grain(.aqua)
        defer { window.close() }
        view.viewDidChangeEffectiveAppearance()
        #expect(!pendingRepaint(view))
        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        #expect(pendingRepaint(view))
        #expect(view.layer?.compositingFilter == nil)
        flush(view)
        view.appearance = NSAppearance(named: .aqua)
        view.viewDidChangeEffectiveAppearance()
        #expect(pendingRepaint(view))
        #expect(view.layer?.compositingFilter as? String == "multiplyBlendMode")
    }

    @Test("Interactive theme frames with an unchanged grain leave the pattern painted")
    func swipeFramesKeepPattern() {
        let fill = OrbitThemeFillView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = hosted(fill)
        defer { window.close() }
        fill.appearance = NSAppearance(named: .aqua)
        fill.paperGrain.viewDidChangeEffectiveAppearance()
        fill.applyInteractiveTheme(.init(stops: [.gray], mode: .automatic, texture: .grain, textureIntensity: 0.3))
        flush(fill.paperGrain)
        #expect(!pendingRepaint(fill.paperGrain))
        for step in 0...20 {
            let t = CGFloat(step) / 20
            let color = NSColor(srgbRed: t, green: 0.4, blue: 1 - t, alpha: 1)
            fill.applyInteractiveTheme(.init(stops: [color], mode: .automatic, texture: .grain, textureIntensity: 0.3))
        }
        #expect(!pendingRepaint(fill.paperGrain))
        fill.applyInteractiveTheme(.init(stops: [.gray], mode: .automatic, texture: .grain, textureIntensity: 0.6))
        #expect(!pendingRepaint(fill.paperGrain))
        #expect(fill.paperGrain.alphaValue == OrbitPaperGrainView.opacity(for: 0.6))
        // A moved fill still re-phases its pattern.
        fill.offsetInWindowFill = CGPoint(x: 12, y: 4)
        fill.layout()
        #expect(pendingRepaint(fill.paperGrain))
    }

    @Test("Floating sidebar backdrop skips identical foreground assignments")
    func backdropForegroundGuard() {
        let backdrop = OrbitFloatingSidebarBackdrop(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        backdrop.foreground = .white
        backdrop.foreground = .white
        #expect(backdrop.foreground == .white)
        backdrop.foreground = .black
        #expect(backdrop.foreground == .black)
    }

    @Test("Symbol tab icons are one shared instance per symbol")
    func symbolTabIconIdentity() throws {
        let catalog = try #require(SpaceIconImages.tabImage(.systemSymbol("star.fill")))
        #expect(SpaceIconImages.tabImage(.systemSymbol("star.fill")) === catalog)
        // A symbol outside the bundled catalog resolves through the system fallback.
        let fallback = try #require(SpaceIconImages.tabImage(.systemSymbol("tortoise.fill")))
        #expect(SpaceIconImages.tabImage(.systemSymbol("tortoise.fill")) === fallback)
        #expect(fallback !== catalog)
        #expect(SpaceIconImages.tabImage(.systemSymbol("star.fill")) !== fallback)
    }

    @Test("Activity snapshots of a symbol-icon tab compare equal across renders")
    func symbolTabActivityEquality() {
        func render() -> SidebarTabActivity {
            SidebarTabActivity(favicon: SpaceIconImages.tabImage(.systemSymbol("tortoise.fill")), isLoading: false)
        }
        #expect(render() == render())
        func renderCatalog() -> SidebarTabActivity {
            SidebarTabActivity(favicon: SpaceIconImages.tabImage(.systemSymbol("star.fill")))
        }
        #expect(renderCatalog() == renderCatalog())
    }

    @Test("Interface glyph copies stay private to each caller")
    func orbitIconCopies() throws {
        let name = try #require(OrbitIcon.templateNames.first)
        let one = try #require(OrbitIcon.image(sfName: name, pointSize: 16, accessibilityDescription: "One"))
        let two = try #require(OrbitIcon.image(sfName: name, pointSize: 16, accessibilityDescription: "Two"))
        #expect(one !== two)
        #expect(one.accessibilityDescription == "One" && two.accessibilityDescription == "Two")
        let size = two.size
        one.size = NSSize(width: 40, height: 40)
        #expect(two.size == size)
        #expect(OrbitIcon.reconfiguredTemplate(two, pointSize: 20, weight: .regular) != nil)
    }
}
