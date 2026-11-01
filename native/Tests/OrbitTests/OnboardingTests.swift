import AppKit
import BrowserCore
import BrowserShell
import Foundation
import QuartzCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
/// First-run onboarding: flow, measured layout and motion, keyboard and VoiceOver, theme recolour,
/// and the main window hand-off.
@Suite(.serialized)
@MainActor
struct OnboardingTests {
    typealias M = OrbitOnboardingMetrics
    static let sources = OnboardingRenderTests.sources

    private final class Recorder {
        var records: [BrowserOnboardingRecord] = []
        var sync: [Bool] = []
        var defaultRequests = 0
        var finished: BrowserOnboardingRecord?
        var committed: [BrowserSpaceTheme?] = []
    }

    private func controller(step: BrowserOnboardingRecord.Step = .welcome, sync: OrbitOnboardingSyncAvailability = .available,
                            sources: [OrbitOnboardingSource] = Self.sources) -> (OrbitOnboardingWindowController, Recorder) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let recorder = Recorder()
        var services = OrbitOnboardingServices()
        services.persist = { recorder.records.append($0) }
        services.setSync = { recorder.sync.append($0) }
        services.requestDefaultBrowser = { recorder.defaultRequests += 1 }
        services.finish = { record, _ in recorder.finished = record }
        let target = OrbitOnboardingThemeTarget(spaceID: SpaceID(), profileID: ProfileID(), stored: nil,
                                                commit: { recorder.committed.append($0) }, registry: nil)
        let flow = OrbitOnboardingFlow(step: step, sources: sources, syncAvailability: sync)
        return (OrbitOnboardingWindowController(flow: flow, services: services, themeTarget: target), recorder)
    }

    private func settle(_ controller: OrbitOnboardingWindowController) async {
        for _ in 0..<200 where controller.isTransitioning {
            for page in controller.card.textClip.subviews { page.layer?.removeAllAnimations() }
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("The single vector asset exposes its strokes for the entrance drawing")
    func markAsset() throws {
        let (_, strokes) = try #require(OrbitOnboardingMarkPaths.read())
        #expect(strokes.count == 5)
        let colors = strokes.compactMap { $0.color.usingColorSpace(.sRGB) }
        #expect(colors.filter { min($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.99 }.count == 2)
        #expect(colors.contains { $0.redComponent > 0.9 && $0.greenComponent < 0.4 })
        #expect(strokes.allSatisfy { !$0.path.isEmpty && $0.width > 0 })
    }

    @Test("Seven steps, profile checkboxes and choices survive a saved record")
    func flow() {
        var flow = OrbitOnboardingFlow(sources: Self.sources, syncAvailability: .available)
        #expect(OrbitOnboardingFlow.steps == [.welcome, .importSource, .favourites, .sync, .theme, .defaultBrowser, .finish])
        #expect(flow.advance() && flow.step == .importSource && flow.hasBack)
        #expect(!flow.canAdvance)
        flow.select(source: Self.sources[1])
        #expect(flow.selectedProfiles.count == 3)
        flow.select(profile: "Profile 1", of: Self.sources[1])
        #expect(flow.selectedProfiles.count == 2)
        #expect(flow.advance() && flow.step == .favourites)
        #expect(flow.goBack() && flow.step == .importSource)
        let record = flow.record(.started)
        let resumed = OrbitOnboardingFlow(step: record.step, sources: Self.sources, syncAvailability: .available, restoring: record)
        #expect(resumed.selectedProfiles == flow.selectedProfiles)
        #expect(resumed.favourites == flow.favourites)
    }

    @Test("Opaque card uses the specified geometry, shared title style and native theme editor")
    func layout() throws {
        let (controller, _) = controller(step: .theme)
        #expect(controller.card.frame == NSRect(x: 120, y: 95, width: 960, height: 560))
        #expect(controller.card.leftPanel.path?.boundingBox.width == 380)
        #expect(controller.card.layer?.cornerRadius == 22)
        #expect(controller.card.layer?.backgroundColor == OrbitOnboardingColors.rightPanel.cgColor)
        #expect(controller.card.primaryButton.frame.size == NSSize(width: 308, height: 48))
        #expect(controller.themeEditor != nil)
        #expect(controller.themeEditor?.view.surfaceScope.isHidden == true)
        #expect(controller.card.page?.counter.stringValue == OrbitOnboardingText.counter(5))
        #expect(controller.window?.styleMask.contains(.resizable) == false)
    }

    @Test("Onboarding offers all color pages while retaining the native editor controls")
    func themePresets() async throws {
        let (controller, recorder) = controller(step: .theme)
        let editor = try #require(controller.themeEditor)
        #expect(editor.view.swatches.filter { !$0.isHidden }.count == 9)
        #expect(editor.view.handles.count == 2)
        #expect(!editor.view.previousButton.isHidden && !editor.view.nextButton.isHidden)
        editor.view.nextButton.performClick(nil)
        editor.view.swatches[3].performClick(nil)
        #expect(editor.draft.colors.last == BrowserSpaceThemePresets.pastel.swatches[3])
        let selected = editor.draft
        controller.primaryAction()
        await settle(controller)
        #expect(controller.step == .defaultBrowser)
        #expect(recorder.committed.last! == selected)
    }

    @Test("Favourites use starter choices and skip clears the selected sites")
    func favourites() async {
        let (controller, _) = controller(step: .favourites)
        #expect(controller.flow.favourites.count == 8)
        #expect(controller.flow.selectedFavourites.count == 3)
        controller.skipAction()
        #expect(controller.flow.favouritesSkipped)
        #expect(controller.flow.selectedFavourites.isEmpty)
        #expect(controller.step == .sync)
        await settle(controller)
    }

    @Test("Returning to a skipped favourites step and selecting a site accepts it again")
    func skippedFavouritesRevisited() async throws {
        let (controller, _) = controller(step: .favourites)
        controller.skipAction()
        await settle(controller)
        controller.backAction()
        await settle(controller)
        let grid = try #require(controller.card.rightView?.subviews.compactMap { $0 as? OrbitOnboardingFavouritesView }.first)
        grid.onToggle?(3)
        #expect(controller.flow.selectedFavourites.count == 1)
        #expect(!controller.flow.favouritesSkipped)
    }

    @Test("Outgoing import controls cannot alter consent while their pane is being replaced")
    func outgoingSelectionBlocked() async throws {
        let (controller, _) = controller(step: .importSource)
        let oldRow = try #require(controller.optionCards.first)
        controller.select(optionAt: 1)
        controller.primaryAction()
        for _ in 0..<200 where controller.step == .importSource { await Task.yield() }
        #expect(controller.isTransitioning)
        oldRow.onSelect?()
        #expect(controller.flow.selectedSource == Self.sources[1])
        await settle(controller)
    }

    @Test("Default request and import finish before the finish stage becomes available")
    func actions() async {
        let recorder = Recorder()
        var order: [String] = []
        var services = OrbitOnboardingServices()
        services.requestDefaultBrowser = { order.append("default") }
        services.isDefaultBrowser = { false }
        services.prepareFinish = { _ in order.append("import"); return 12.6 }
        services.importSummary = { .init(spaces: 3, pinnedTabs: 12, passwords: 2) }
        services.enteredFinish = { _ in order.append("ready") }
        services.finish = { record, _ in recorder.finished = record }
        let flow = OrbitOnboardingFlow(step: .defaultBrowser, sources: [], syncAvailability: .unavailable)
        let controller = OrbitOnboardingWindowController(flow: flow, services: services, themeTarget: nil)
        controller.select(optionAt: 0)
        controller.primaryAction()
        for _ in 0..<200 where controller.step != .finish { await Task.yield() }
        #expect(order == ["default", "import", "ready"])
        #expect(controller.flow.defaultBrowserChoice == false)
        #expect(controller.flow.importDuration == 12.6 && controller.flow.importApplied)
        #expect(controller.flow.record(.started).importSummary == .init(spaces: 3, pinnedTabs: 12, passwords: 2))
        controller.primaryAction()
        #expect(recorder.finished?.state == .completed)
        let (declining, declined) = self.controller(step: .defaultBrowser)
        declining.select(optionAt: 1)
        declining.primaryAction()
        for _ in 0..<100 { await Task.yield() }
        #expect(declined.defaultRequests == 0)
    }

    @Test("Finish sticker variants use measured duration only when an import ran")
    func stickers() {
        #expect(OrbitOnboardingText.sticker(duration: nil, sync: false) == uiText("nothing uploaded"))
        #expect(OrbitOnboardingText.sticker(duration: nil, sync: true) == uiText("synced to your iCloud"))
        #expect(OrbitOnboardingText.sticker(duration: 12.6, sync: false) == uiFormat("%d s · %@", 13, uiText("nothing uploaded")))
        #expect(OrbitOnboardingText.sticker(duration: 12.6, sync: true) == uiFormat("%d s · %@", 13, uiText("synced to your iCloud")))
        #expect(OrbitOnboardingText.sticker(duration: 0.2, sync: false) == uiFormat("%d s · %@", 1, uiText("nothing uploaded")))
    }

    @Test("Checkbox profiles and radio choices expose accessible labels")
    func accessibility() {
        let (controller, _) = controller(step: .importSource)
        controller.select(optionAt: 1)
        #expect(controller.profileList?.rows.allSatisfy { $0.accessibilityRole() == .checkBox } == true)
        #expect(controller.optionCards.allSatisfy { $0.accessibilityRole() == .radioButton && !($0.accessibilityLabel() ?? "").isEmpty })
    }

    @Test("Admission: the product's default session, or an explicit synthetic opt-in")
    func admission() {
        let product = ProductIdentity.bundleIdentifier
        #expect(OrbitApplication.onboardingAdmitted(bundleIdentifier: product, arguments: ["Orbit"], hasSessionFile: true, synthetic: false))
        #expect(!OrbitApplication.onboardingAdmitted(bundleIdentifier: product, arguments: ["Orbit", "--ephemeral"], hasSessionFile: true, synthetic: false))
        #expect(!OrbitApplication.onboardingAdmitted(bundleIdentifier: product, arguments: ["Orbit", "--session-file", "/x"], hasSessionFile: true, synthetic: false))
        #expect(!OrbitApplication.onboardingAdmitted(bundleIdentifier: product, arguments: ["Orbit"], hasSessionFile: false, synthetic: false))
        #expect(!OrbitApplication.onboardingAdmitted(bundleIdentifier: "lab.orbit.orbit.synthetic", arguments: ["Orbit"], hasSessionFile: true, synthetic: true))
        #expect(OrbitApplication.onboardingAdmitted(bundleIdentifier: "lab.orbit.orbit.onboard-1", arguments: ["Orbit", "--offer-onboarding"], hasSessionFile: true, synthetic: true))
        #expect(!OrbitApplication.onboardingAdmitted(bundleIdentifier: "io.github.okatech.orbit.test.orbit.live", arguments: ["Orbit"], hasSessionFile: true, synthetic: false))
    }

    @Test("Main windows wait behind the onboarding, then take its frame in one transaction")
    func handOff() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        var presented: [(OrbitWindowController, Bool)] = []
        let app = OrbitApplication(environment: environment, windowPresenter: { presented.append(($0, $1)) })
        defer { app.windows.shutdown() }
        let (onboarding, _) = controller(step: .finish, sources: [])
        app.onboarding = onboarding
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        #expect(presented.isEmpty && app.heldOnboardingWindows.count == 1)
        onboarding.window?.setFrameOrigin(NSPoint(x: 40, y: 60))
        let frame = try #require(onboarding.window?.frame)
        var finished: BrowserOnboardingRecord?
        app.onOnboardingFinished = { finished = $0 }
        let base = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        let directory = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("orbit-onboarding-handoff-\(UUID().uuidString)")
        free(base)
        defer { try? FileManager.default.removeItem(at: directory) }
        app.completeOnboarding(BrowserOnboardingRecord(state: .completed, step: .finish), controller: onboarding, dataDirectory: directory)
        #expect(presented.count == 1 && presented.first?.1 == true)
        #expect(presented.first?.0.window?.frame == frame)
        #expect(app.onboarding == nil && app.heldOnboardingWindows.isEmpty && finished?.state == .completed)
        #expect(onboarding.window?.isVisible != true)
        #expect(try BrowserOnboardingFiles.load(dataDirectory: directory)?.state == .completed)
    }

    @Test("Opening an existing (v0.24-shaped) session writes no onboarding state and leaves it byte-equal")
    func existingSessionUntouched() async throws {
        let base = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        let directory = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("orbit-onboarding-open-\(UUID().uuidString)")
        free(base)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionFile = directory.appendingPathComponent("session.json")
        let seed = try await PreviewEnvironment.open(sessionFile: sessionFile)
        _ = try await seed.initialContext.value
        #expect(seed.launchedOnFreshDataDirectory)
        try await seed.saveNow()
        try await seed.finalize()
        _ = await seed.shutDown()
        let before = try Data(contentsOf: sessionFile)
        let environment = try await PreviewEnvironment.open(sessionFile: sessionFile)
        #expect(!environment.launchedOnFreshDataDirectory)
        #expect(BrowserOnboardingDecision.decide(admitted: true, record: try BrowserOnboardingFiles.load(dataDirectory: directory),
                                                 fresh: environment.launchedOnFreshDataDirectory) == .none)
        #expect(!FileManager.default.fileExists(atPath: BrowserOnboardingFiles.directory(dataDirectory: directory).path))
        #expect(try Data(contentsOf: sessionFile) == before)
        try await environment.finalize()
        _ = await environment.shutDown()
    }
}
}

extension NativeWebKitTests.OnboardingTests {
    @Test("Default-browser preview refreshes its existing tint when its appearance changes")
    @MainActor
    func promptAppearanceChanges() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = original }
        let host = NSView()
        host.appearance = NSAppearance(named: .aqua)
        let preview = OrbitOnboardingPromptMock(frame: NSRect(x: 0, y: 0, width: 300, height: 230))
        host.addSubview(preview)
        let material = try #require(preview.subviews.first as? NSVisualEffectView)
        let tint = try #require(preview.subviews.dropFirst().first?.layer?.sublayers?.first)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        preview.viewDidChangeEffectiveAppearance()
        let color = try #require(tint.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        #expect(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0)
        #expect(color.alphaComponent == BrandPalette.Frost.tint)
        preview.refreshMaterial(reduceTransparency: true)
        #expect(material.isHidden)
        #expect(tint.backgroundColor?.alpha == 1)
        preview.refreshMaterial(reduceTransparency: false)
        #expect(!material.isHidden)
        #expect(tint.backgroundColor?.alpha == BrandPalette.Frost.tint)
    }
}
