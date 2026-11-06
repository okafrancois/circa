import AppKit
import BrowserCore
import Darwin
import Foundation
import BrowserEngine
import BrowserEngineConformance
import Testing
@testable import Orbit

private let window = CGSize(width: 1024, height: 640)

@Suite("Edge-to-edge page geometry")
struct PageEdgeGeometryTests {
    @Test("By default the docked card is flush with the top, trailing and bottom edges and rounds its leading corners")
    func edgeDocked() {
        let geometry = OrbitShellGeometry.resolve(.init(contentSize: window, spaceAroundPages: false))
        #expect(geometry.cardFrame == CGRect(x: 228, y: 0, width: 796, height: 640))
        #expect(geometry.cardRadius == OrbitTokens.Metrics.Content.edgeCardLeadingRadius && geometry.isCardFlush)
        #expect(geometry.cardGap == 0)
        let fullScreen = OrbitShellGeometry.resolve(.init(contentSize: window, isFullScreen: true, spaceAroundPages: false))
        #expect(fullScreen.cardFrame == geometry.cardFrame && fullScreen.cardRadius == geometry.cardRadius)
        let wide = OrbitShellGeometry.resolve(.init(contentSize: window, sidebarWidth: 300, spaceAroundPages: false))
        #expect(wide.cardFrame == CGRect(x: 300, y: 0, width: 724, height: 640))
    }

    @Test("Hiding the sidebar opens the leading corners and fills the window, windowed or full screen")
    func edgeHidden() {
        for isFullScreen in [false, true] {
            let hidden = OrbitShellGeometry.resolve(.init(contentSize: window, dockProgress: 0, isFullScreen: isFullScreen,
                                                          spaceAroundPages: false))
            #expect(hidden.cardFrame == CGRect(origin: .zero, size: window) && hidden.cardRadius == 0)
            let floating = OrbitShellGeometry.resolve(.init(contentSize: window, dockProgress: 0, floatProgress: 1,
                                                            isFullScreen: isFullScreen, spaceAroundPages: false))
            #expect(floating.cardFrame == hidden.cardFrame)
        }
        let half = OrbitShellGeometry.resolve(.init(contentSize: window, dockProgress: 0.5, spaceAroundPages: false))
        #expect(half.cardFrame.minY == 0 && half.cardFrame.maxX == window.width && half.cardFrame.maxY == window.height)
        #expect(half.cardRadius > 0 && half.cardRadius < OrbitTokens.Metrics.Content.edgeCardLeadingRadius)
    }

    @Test("Space around pages restores the spaced card exactly")
    func spacedIsLegacy() {
        for dock in [CGFloat(0), 0.5, 1] {
            for isFullScreen in [false, true] {
                let spaced = OrbitShellGeometry.resolve(.init(contentSize: window, dockProgress: dock, isFullScreen: isFullScreen,
                                                              spaceAroundPages: true))
                let legacy = OrbitShellGeometry.resolve(.init(contentSize: window, dockProgress: dock, isFullScreen: isFullScreen))
                #expect(spaced == legacy && !spaced.isCardFlush)
            }
        }
        let docked = OrbitShellGeometry.resolve(.init(contentSize: window, spaceAroundPages: true))
        #expect(docked.cardFrame == CGRect(x: 228, y: 10, width: 786, height: 620) && docked.cardRadius == 6)
    }

    @Test("A selective corner path squares the corners that are not masked")
    func cornerPath() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        let leading = OrbitCornerPath.path(rect, radius: 14, corners: OrbitCornerPath.leadingCorners)
        #expect(leading.boundingBoxOfPath.insetBy(dx: -0.01, dy: -0.01).contains(rect.insetBy(dx: 0.01, dy: 0.01)))
        #expect(leading.contains(CGPoint(x: 99.5, y: 0.5)) && leading.contains(CGPoint(x: 99.5, y: 59.5)))
        #expect(!leading.contains(CGPoint(x: 0.5, y: 0.5)) && !leading.contains(CGPoint(x: 0.5, y: 59.5)))
    }
}

@Suite("Edge-to-edge page card")
@MainActor
struct PageEdgeCardTests {
    @Test("A flush card rounds only its leading corners and casts the soft edge shadow; the spaced card is unchanged")
    func flushCard() {
        let card = BrowserContentCardView()
        #expect(card.pageCorners == OrbitCornerPath.allCorners)
        #expect(card.shadowSpec?.blur == OrbitTokens.Shadow.contentCard.blur)
        card.isFlushWithWindow = true
        #expect(card.pageCorners == OrbitCornerPath.leadingCorners)
        #expect(card.assistantCorners == OrbitCornerPath.leadingCorners)
        #expect(card.shadowSpec?.blur == OrbitTokens.Shadow.contentCardEdge.blur)
        #expect(card.shadowSpec?.offsetY == 0)
        card.isFlushWithWindow = false
        #expect(card.pageCorners == OrbitCornerPath.allCorners)
        #expect(card.shadowSpec?.offsetY == OrbitTokens.Shadow.contentCard.offsetY)
    }
}

@Suite("Space around pages preference")
struct PageSpacingPreferenceTests {
    @Test("Absent means edge to edge; the choice persists and a malformed value falls back without rewriting")
    func persistence() async throws {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("page-spacing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let store = try BrowserSettingsStore(destination: file)
        #expect(await store.snapshot().showsSpaceAroundPages == false)
        try await store.setShowsSpaceAroundPages(true)
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().showsSpaceAroundPages)

        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["showsSpaceAroundPages"] as? Bool == true)
        json.removeValue(forKey: "showsSpaceAroundPages")
        let absent = try JSONSerialization.data(withJSONObject: json)
        try absent.write(to: file)
        let migrated = try BrowserSettingsStore(destination: file)
        #expect(await migrated.snapshot().showsSpaceAroundPages == false)
        #expect(try Data(contentsOf: file) == absent)

        json["showsSpaceAroundPages"] = "yes"
        let malformed = try JSONSerialization.data(withJSONObject: json)
        try malformed.write(to: file)
        let recovered = try BrowserSettingsStore(destination: file)
        #expect(await recovered.snapshot().showsSpaceAroundPages == false)
        #expect(await recovered.snapshot().memorySaver == .oneHour)
    }
}

extension NativeWebKitTests {
@Suite("Space around pages in live windows", .serialized)
@MainActor
struct PageSpacingLiveTests {
    @Test("Toggling the preference re-lays out an open window both ways")
    func liveToggle() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.autoArchive.scheduler.stop() }
        let root = try #require(controller.window?.contentView)
        func settle() { controller.windowShell.applyGeometry(); root.layoutSubtreeIfNeeded() }
        settle()
        #expect(!environment.settings.document.showsSpaceAroundPages)
        let size = root.bounds.size
        #expect(controller.contentCard.frame.minY == 0 && controller.contentCard.frame.maxX == size.width)
        #expect(controller.contentCard.frame.height == size.height && controller.contentCard.isFlushWithWindow)

        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [])
        try await model.setShowsSpaceAroundPages(true)
        settle()
        #expect(controller.contentCard.frame.minY == 10 && controller.contentCard.frame.maxX == size.width - 10)
        #expect(controller.contentCard.cornerRadius == OrbitTokens.Radius.contentCard && !controller.contentCard.isFlushWithWindow)

        try await model.setShowsSpaceAroundPages(false)
        settle()
        #expect(controller.contentCard.frame.minY == 0 && controller.contentCard.isFlushWithWindow)
    }
}
}
