import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Test("Space swipe preview paints the saved selected row only for its own window and Space")
@MainActor
func spaceSwipeSavedSelectionAppearance() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic selection")
    let first = try await store.createSpace(name: "First", profileID: profile)
    let second = try await store.createSpace(name: "Second", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: second)
    let context = try await store.captureContext(in: window)
    let occurrence = try await store.openTab(url: URL(string: "https://synthetic.invalid/selected")!, from: context, activate: true)
    try await store.activateSpace(first, in: window)
    let before = await store.sessionDocument()
    let selected = try #require(before.tabs.first { $0.occurrenceID == occurrence }?.id)
    let preview = SpaceSwipePreview.content(document: before, spaceID: second, windowID: window)
    #expect(preview.tabs.filter(\.selected).map(\.id) == [selected])
    #expect(preview.tabs.allSatisfy { $0.occurrenceID == nil })
    #expect(SpaceSwipePreview.content(document: before, spaceID: second, windowID: WindowID()).tabs.allSatisfy { !$0.selected })
    #expect(await store.sessionDocument() == before)
}
}

extension NativeWebKitTests {
@Test("Space swipe theme progress uses captured endpoints, follows appearance, restores selected theme")
@MainActor
func spaceSwipeThemeProgressAndRestore() {
    let shell = OrbitWindowShell()
    let source = OrbitTokens.SpaceTheme.amberCoral
    let target = OrbitTokens.SpaceTheme.lavender
    shell.apply(theme: source, animated: false)
    shell.applySpaceSwipeBlend(.init(source: source, destination: target, progress: 0.5))
    #expect(shell.theme == source)
    #expect(!shell.themeFill.isCrossfading)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = NSAppearance(named: name)!
        shell.themeFill.appearance = appearance
        shell.themeFill.viewDidChangeEffectiveAppearance()
        let actual = shell.themeFill.resolvedStops.map { NSColor(cgColor: $0)!.usingColorSpace(.sRGB)! }
        let a = OrbitThemeGradient.normalizedStops(source.stops, appearance: appearance).map { NSColor(cgColor: $0)!.usingColorSpace(.sRGB)! }
        let b = OrbitThemeGradient.normalizedStops(target.stops, appearance: appearance).map { NSColor(cgColor: $0)!.usingColorSpace(.sRGB)! }
        for index in 0..<3 {
            #expect(abs(actual[index].redComponent - (a[index].redComponent + b[index].redComponent) / 2) < 0.001)
            #expect(abs(actual[index].greenComponent - (a[index].greenComponent + b[index].greenComponent) / 2) < 0.001)
            #expect(abs(actual[index].blueComponent - (a[index].blueComponent + b[index].blueComponent) / 2) < 0.001)
        }
    }
    shell.applySpaceSwipeBlend(nil)
    #expect(shell.themeFill.theme == source)
    #expect(shell.floatingBackdrop.fill.theme == source)
    shell.applySpaceSwipeBlend(.init(source: source, destination: target, progress: 0.6))
    shell.apply(theme: target, animated: false)
    #expect(shell.themeFill.theme != target)
    shell.applySpaceSwipeBlend(nil)
    #expect(shell.themeFill.theme == target)
}
}

@MainActor
private final class BackgroundCountingWindow: NSWindow {
    var backgroundAssignments = 0
    override var backgroundColor: NSColor! {
        get { super.backgroundColor }
        set { backgroundAssignments += 1; super.backgroundColor = newValue }
    }
}

extension NativeWebKitTests {
@Test("Swipe theme frames only repaint the gradient: no grain redraw or equal window background")
@MainActor
func spaceSwipeThemeFramesAreIncremental() {
    let window = BackgroundCountingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                          styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let shell = OrbitWindowShell()
    var source = OrbitTokens.SpaceTheme.amberCoral
    source.texture = .grain
    source.textureIntensity = 0.5
    var target = OrbitTokens.SpaceTheme.lavender
    target.texture = .grain
    target.textureIntensity = 0.5
    let root = OrbitWindowRootView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    window.contentView = root
    shell.prepare(window: window, root: root)
    shell.apply(theme: source, animated: false)
    func flush(_ layer: CALayer?) { layer?.displayIfNeeded(); layer?.sublayers?.forEach(flush) }
    flush(shell.themeFill.layer)
    #expect(!shell.themeFill.grainNeedsDisplay)
    shell.applySpaceSwipeBlend(.init(source: source, destination: target, progress: 0.2))
    let assignments = window.backgroundAssignments
    for step in 3...9 {
        shell.applySpaceSwipeBlend(.init(source: source, destination: target, progress: CGFloat(step) / 10))
        #expect(!shell.themeFill.grainNeedsDisplay)
    }
    #expect(!window.isOpaque)
    #expect(window.backgroundAssignments - assignments <= 7)
    shell.applySpaceSwipeBlend(nil)
    #expect(shell.themeFill.theme == source)
}
}
