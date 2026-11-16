import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

/// Registry stand-in that pays a realistic decode for every snapshot and counts requests.
@MainActor
private final class CountingExtensionHost: BrowserExtensionHost {
    var supportsActions = true
    var supportsPinning = true
    var onExtensionsChange: ((ProfileID) -> Void)?
    let changes = BrowserExtensionChangeHub()
    var surfaceSnapshots = 0
    var payload = Data()
    var badge = "1"

    init(count: Int) {
        let icon = NativeWebKitTests.NativeFaviconReceiptTests.png(16).base64EncodedString()
        let items = (0..<count).map { index in
            var item = BrowserExtensionSummary(id: String(repeating: Character(UnicodeScalar(97 + index)!), count: 32),
                                               name: "Synthetic \(index)", version: "1.0.\(index)", isEnabled: true, hasAction: true)
            item.isPinned = true
            item.iconPNGBase64 = icon
            return item
        }
        payload = try! JSONEncoder().encode(items)
    }
    func observeChanges(in profileID: ProfileID, handler: @escaping () -> Void) throws -> BrowserExtensionObservation {
        changes.observe(in: profileID, handler: handler)
    }
    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary] {
        try JSONDecoder().decode([BrowserExtensionSummary].self, from: payload)
    }
    func installedExtensions(on surface: any BrowserEngineSurface) throws -> [BrowserExtensionSummary] {
        surfaceSnapshots += 1
        var items = try installedExtensions(in: surface.profileID)
        items[0].actionState = .init(title: "Action", badgeText: badge, badgeBackgroundColor: 0xffff0000, isEnabled: true)
        return items
    }
    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws {}
    func setPinned(_ pinned: Bool, extensionID: String, in profileID: ProfileID) throws {}
    func remove(extensionID: String, in profileID: ProfileID) throws {}
    func openManagement(on surface: any BrowserEngineSurface) throws {}
    func openDetails(extensionID: String, on surface: any BrowserEngineSurface) throws {}
    func openShortcuts(on surface: any BrowserEngineSurface) throws {}
    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws {}
}

@MainActor
private func microseconds(_ iterations: Int, _ body: () throws -> Void) rethrows -> Double {
    let start = ContinuousClock.now
    for _ in 0..<iterations { try body() }
    let elapsed = start.duration(to: .now)
    return Double(elapsed.components.seconds) * 1e6 / Double(iterations)
        + Double(elapsed.components.attoseconds) / 1e12 / Double(iterations)
}

/// A visible 32 px favicon; `hue` makes each one a distinct image.
@MainActor
private func visibleIcon(hue: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: 32, height: 32))
    image.lockFocus()
    NSColor(hue: hue, saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 24, height: 24)).fill()
    image.unlockFocus()
    return image
}

private let benchmarksEnabled = ProcessInfo.processInfo.environment["ORBIT_SHELL_COST_BENCH"] != nil

extension NativeWebKitTests {
@Suite("Shell main-thread costs", .serialized)
@MainActor
struct ShellMainThreadCostTests {
    private func iconDirectory() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-shell-cost-\(UUID())")
    }

    @Test("Missing sidebar icons are remembered until the disk store changes")
    func sidebarNegativeCache() async throws {
        let directory = iconDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ProfileID()
        let store = FavoriteIconStore(directory: directory)
        let sidebar = SidebarIconMemoryCache(store: store)
        let home = URL(string: "https://missing.example.test/page")!
        #expect(sidebar.image(profile: profile, home: home) == nil)
        #expect(sidebar.missCount == 1)
        // A file that appears behind the store's back is not looked up again...
        let pixels = try #require(BrowserFaviconImage(sourceURL: home, png: NativeFaviconReceiptTests.png()))
        let file = try #require(store.cachedFile(profile: profile, home: home))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pixels.png.write(to: file)
        #expect(sidebar.image(profile: profile, home: home) == nil)
        #expect(sidebar.missCount == 1)
        // ...but any write through the store invalidates the remembered misses.
        let other = URL(string: "https://other.example.test/")!
        await store.put(try #require(BrowserFaviconImage(sourceURL: other, png: NativeFaviconReceiptTests.png())),
                        profile: profile, home: other)
        #expect(sidebar.image(profile: profile, home: home) != nil)
        #expect(sidebar.missCount == 0)
        // Storing an icon in memory clears its own miss at once.
        let late = URL(string: "https://late.example.test/")!
        #expect(sidebar.image(profile: profile, home: late) == nil)
        let image = try #require(await pixels.nativeImage())
        sidebar.put(image, profile: profile, home: late)
        #expect(sidebar.image(profile: profile, home: late) === image)
        #expect(sidebar.missCount == 0)
        // Profile removal and memory pressure forget misses too.
        #expect(sidebar.image(profile: profile, home: URL(string: "https://gone.example.test/")!) == nil)
        sidebar.releaseMemory()
        #expect(sidebar.missCount == 0)
    }

    @Test("Favorite tile icon analysis runs once per source image")
    func tilePresentationMemo() throws {
        let first = visibleIcon(hue: 0.1), second = visibleIcon(hue: 0.6)
        let a = try #require(FavoriteTileView.iconPresentation(first))
        let b = try #require(FavoriteTileView.iconPresentation(first))
        let c = try #require(FavoriteTileView.iconPresentation(second))
        #expect(a.image === b.image && a.tint == b.tint)
        #expect(c.image !== a.image)
        #expect(a.image !== first)
        let fresh = try #require(FavoriteTileView.analyzedIconPresentation(first))
        #expect(fresh.tint == a.tint && fresh.image.isTemplate == a.image.isTemplate)
    }

    @Test("Extension inventory is reused until the engine reports a change or the document changes")
    func extensionSnapshotReuse() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine(), host = CountingExtensionHost(count: 3)
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        owner.submitAddress("https://extensions.example.invalid/one")
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        owner.extensionControls.render()
        let baseline = host.surfaceSnapshots
        for _ in 0..<10 { owner.extensionControls.render() }
        #expect(host.surfaceSnapshots == baseline)
        let anchor = try #require(owner.sidebar.extensionsContainer.subviews.compactMap { $0 as? NSButton }.first)
        let badge = try #require(anchor.subviews.compactMap { $0 as? BrowserExtensionBadgeView }.first)
        #expect(badge.text == "1")
        host.badge = "2"
        host.changes.emit(surface.profileID)
        #expect(host.surfaceSnapshots == baseline + 1)
        #expect(badge.text == "2")
        owner.extensionControls.render()
        #expect(host.surfaceSnapshots == baseline + 1)
        let generation = surface.documentGeneration, preNavigation = host.surfaceSnapshots
        owner.submitAddress("https://extensions.example.invalid/two")
        await owner.session.waitForPendingCommands()
        owner.extensionControls.render()
        if owner.session.selectedSurface?.documentGeneration != generation {
            // A new document never reuses the previous document's action values.
            #expect(host.surfaceSnapshots > preNavigation)
        }
        let settled = host.surfaceSnapshots
        owner.extensionControls.render()
        #expect(host.surfaceSnapshots == settled)
        owner.extensionControls.releaseMemory()
        let released = host.surfaceSnapshots
        owner.extensionControls.render()
        #expect(host.surfaceSnapshots == released + 1)
        try await environment.finalize()
    }

    @Test("Empty-state artwork is decoded once and re-asserting the state changes nothing")
    func emptyStateArtwork() throws {
        let image = BrowserContentCardView.emptyArtworkImage("page-private")
        #expect(image != nil)
        #expect(BrowserContentCardView.emptyArtworkImage("page-private") === image)
        let card = BrowserContentCardView()
        card.emptyStateIsPrivate = true
        let artwork = card.emptyStateArtwork
        #expect(artwork.image === image)
        card.emptyStateIsPrivate = true
        #expect(artwork.image === image && !artwork.isHidden)
        card.emptyStateIsPrivate = false
        #expect(artwork.isHidden)
    }

    @Test("Main-thread cost before and after (benchmark)", .enabled(if: benchmarksEnabled))
    func benchmark() async throws {
        var lines: [String] = []
        // Sidebar refresh of 100 rows without a known icon.
        let directory = iconDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ProfileID(), store = FavoriteIconStore(directory: directory)
        let homes = (0..<100).map { URL(string: "https://row\($0).example.test/")! }
        let sidebar = SidebarIconMemoryCache(store: store)
        let oldMiss = microseconds(20) {
            for home in homes {
                _ = store.cachedFile(profile: profile, home: home).flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            }
        }
        let firstPass = microseconds(1) { for home in homes { _ = sidebar.image(profile: profile, home: home) } }
        let warmPass = microseconds(20) { for home in homes { _ = sidebar.image(profile: profile, home: home) } }
        lines.append(String(format: "sidebar 100-row refresh, no icons: before %.0f µs, after first %.0f µs, after warm %.1f µs", oldMiss, firstPass, warmPass))
        // Favorite tile icon analysis.
        let icons = (0..<32).map { visibleIcon(hue: CGFloat($0) / 32) }
        var index = 0
        let analysis = microseconds(32) { _ = FavoriteTileView.analyzedIconPresentation(icons[index % 32]); index += 1 }
        for icon in icons { _ = FavoriteTileView.iconPresentation(icon) }
        let memo = microseconds(320) { _ = FavoriteTileView.iconPresentation(icons[index % 32]); index += 1 }
        lines.append(String(format: "favorite tile icon presentation: before %.0f µs/tile, after %.2f µs/tile", analysis, memo))
        // Empty-state artwork per projection.
        let artwork = microseconds(50) {
            let image = BrowserText.secondaryBrandResource("page-private", extension: "png").flatMap { NSImage(contentsOf: $0) }
            _ = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let card = BrowserContentCardView()
        card.emptyStateIsPrivate = true
        let guarded = microseconds(500) { card.emptyStateIsPrivate = true }
        lines.append(String(format: "empty-state artwork per projection: before %.0f µs (read + decode), after %.2f µs", artwork, guarded))
        // Extension inventory per session projection, 5 pinned extensions.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine(), host = CountingExtensionHost(count: 5)
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let owner = try await environment.makeWindow()
        owner.submitAddress("https://extensions.example.invalid/one")
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        owner.extensionControls.render()
        let refetch = microseconds(200) { host.changes.emit(surface.profileID) }
        let reuse = microseconds(200) { owner.extensionControls.render() }
        let snapshot = try microseconds(200) { _ = try host.installedExtensions(on: surface) }
        lines.append(String(format: "extension strip per projection (5 pins): refetch render %.0f µs, cached render %.0f µs; snapshot decode avoided %.0f µs (engine-side serialization not included)", refetch, reuse, snapshot))
        owner.session.close(); owner.window?.close()
        try await environment.finalize()
        print("SHELL-COST-BENCH\n" + lines.joined(separator: "\n"))
    }
}
}

