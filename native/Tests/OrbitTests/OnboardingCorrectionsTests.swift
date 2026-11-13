import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

@Suite(.serialized) @MainActor
struct OnboardingCorrectionsTests {
    @Test("An empty import list explains the state and Next continues without an import")
    func emptyImport() async throws {
        let flow = OrbitOnboardingFlow(step: .importSource, sources: [], syncAvailability: .available)
        let controller = OrbitOnboardingWindowController(flow: flow, services: .init(), themeTarget: nil)
        #expect(controller.card.page?.body.stringValue == OrbitOnboardingText.noBrowsers)
        #expect(controller.optionCards.isEmpty)
        #expect(controller.card.skipButton.isHidden)
        #expect(controller.card.primaryButton.title == OrbitOnboardingText.next)
        #expect(controller.card.primaryButton.isEnabled)
        let art = try #require(controller.card.rightView?.subviews.compactMap { $0 as? OrbitOnboardingTrajectoryArt }.first)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(art.sourceName == nil && art.sourceLabel.isHidden)
        controller.card.primaryButton.performClick(nil)
        #expect(controller.step == .favourites)
        #expect(controller.flow.importChoice == BrowserOnboardingRecord.ImportChoice.none)
    }

    @Test("Detected import choices retain consent and the scope uses the monospaced role")
    func foundImport() throws {
        let sources = OnboardingRenderTests.sources
        var flow = OrbitOnboardingFlow(step: .importSource, sources: sources, syncAvailability: .available)
        flow.select(source: sources[0])
        let controller = OrbitOnboardingWindowController(flow: flow, services: .init(), themeTarget: nil)
        #expect(controller.optionCards.count == sources.count)
        #expect(!controller.card.skipButton.isHidden)
        #expect(controller.card.primaryButton.title == OrbitOnboardingText.bringOver)
        let scroll = try #require(controller.card.rightView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let scope = try #require(scroll.documentView?.subviews.compactMap { $0 as? NSTextField }.first)
        let attributes = scope.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        let font = try #require(attributes[.font] as? NSFont)
        #expect(scope.font?.fontName == "DMMono-Regular" && font.fontName == "DMMono-Regular")
        #expect(abs(font.pointSize - 16.58) < 0.01)
        #expect(abs(((attributes[.kern] as? NSNumber)?.doubleValue ?? 0) - 0.663) < 0.01)
        let paragraph = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)
        #expect(paragraph.minimumLineHeight == 26.53 && paragraph.maximumLineHeight == 26.53)
        #expect((attributes[.foregroundColor] as? NSColor)?.alphaComponent == 0.75)
        let art = try #require(controller.card.rightView?.subviews.compactMap { $0 as? OrbitOnboardingTrajectoryArt }.first)
        #expect(art.sourceName == sources[0].name)
    }

    @Test("Only favourites mute Back; transaction and finish keep the underlined link styling")
    func backStyles() throws {
        for step in [BrowserOnboardingRecord.Step.favourites, .sync, .theme, .defaultBrowser] {
            let controller = OrbitOnboardingWindowController(flow: .init(step: step, sources: [], syncAvailability: .available), services: .init(), themeTarget: nil)
            #expect(controller.card.backButton.isUnderlined == (step != .favourites))
            #expect(abs(controller.card.backButton.alphaValue - (step == .favourites ? 0.6 : 1)) < 0.0001)
        }
        let finish = OrbitOnboardingFinishView(frame: .zero)
        #expect(finish.back.isUnderlined && finish.back.alphaValue == 1 && !finish.back.isEnabled)
        let progress = OrbitOnboardingImportProgressView(frame: .zero)
        let back = try #require(progress.subviews.compactMap { $0 as? OrbitOnboardingLinkButton }.first)
        #expect(back.isUnderlined && back.alphaValue == 1 && !back.isEnabled)
    }

    @Test("Every fallback tile still exposes its title without a visible label")
    func tileAccessibility() throws {
        let sites = BrowserOnboardingFavourite.starter
        let grid = OrbitOnboardingFavouritesView(sites: sites)
        let buttons = grid.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 8)
        for (index, site) in sites.enumerated() {
            let button = try #require(buttons.first { $0.tag == index })
            #expect(button.toolTip == site.title)
            #expect(button.accessibilityLabel() == site.title)
            #expect(button.title.isEmpty)
        }
    }

    @Test("The chosen first Space survives persistence in both appearances", arguments: 0..<4, [false, true])
    func firstSpace(index: Int, night: Bool) async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("onboarding-space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserStore(), profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: uiText("Space"), profileID: profile)
        let other = try await store.createSpace(name: "Other", profileID: profile)
        let settings = try BrowserSettingsStore(destination: root.appendingPathComponent("settings.json"))
        try await settings.updateSpace(other) { $0.iconSelection = .grapheme("🧪") }
        let target = OrbitOnboardingThemeTarget(spaceID: space, profileID: profile, stored: nil, commit: { theme in
            try await OrbitOnboardingFirstSpace.apply(theme, spaceID: space, profileID: profile, store: store, settings: settings)
        }, registry: nil)
        let controller = OrbitOnboardingWindowController(flow: .init(step: .theme, sources: [], syncAvailability: .available), services: .init(), themeTarget: target)
        let planet = try #require(controller.card.rightView?.subviews.compactMap { $0 as? OrbitOnboardingPlanetButton }.first { $0.planetIndex == index })
        planet.performClick(nil)
        controller.card.primaryButton.performClick(nil)
        for _ in 0..<300 where controller.isTransitioning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.step == .defaultBrowser)
        let file = root.appendingPathComponent("session.json")
        try BrowserSessionFileStore().save(await store.sessionDocument(), to: file)
        let restored = try BrowserSessionFileStore().load(from: file)
        let saved = try #require(restored.spaces.first { $0.id == space })
        let preferences = try BrowserSettingsStore(destination: root.appendingPathComponent("settings.json"))
        let snapshot = await preferences.snapshot()
        #expect(saved.name == OrbitOnboardingFirstSpace.name)
        #expect(saved.theme == BrandPalette.spaceGradients[index].theme())
        #expect(snapshot.space(space).iconSelection == .planet(BrowserSpacePlanet.selectable[index]))
        #expect(snapshot.space(other).iconSelection == .grapheme("🧪"))
        let theme = try #require(saved.theme)
        let appearance = NSAppearance(named: night ? .darkAqua : .aqua)!
        let rendered = OrbitSpaceThemes.rendered(theme)
        #expect(rendered.mode == .light)
        for (stop, value) in zip(rendered.stops, BrandPalette.spaceGradients[index].stops) {
            #expect(stop.resolved(for: appearance) == OrbitSpaceThemes.color(value))
        }
    }
}
