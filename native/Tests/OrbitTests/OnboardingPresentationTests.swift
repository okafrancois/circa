import AppKit
import CoreText
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

@Suite @MainActor struct OnboardingPresentationTests {
    @Test("Cached favicons paint immediately and the mini sidebar follows a tile selection")
    func cachedPreview() throws {
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        var requests = 0
        var services = OrbitOnboardingServices()
        services.cachedFavicon = { _ in icon }
        services.favicon = { _ in requests += 1; return nil }
        let flow = OrbitOnboardingFlow(step: .favourites, sources: [], syncAvailability: .available)
        let controller = OrbitOnboardingWindowController(flow: flow, services: services, themeTarget: nil)
        let panel = try #require(controller.card.rightView)
        let grid = try #require(panel.subviews.compactMap { $0 as? OrbitOnboardingFavouritesView }.first)
        let preview = try #require(panel.subviews.compactMap { $0 as? OrbitOnboardingMiniPreview }.first)
        #expect(grid.icons.count == flow.favourites.count)
        #expect(preview.icons[flow.favourites[0].url] === icon)
        grid.onToggle?(4)
        #expect(preview.sites.filter(\.selected).count == 4)
        #expect(preview.sites == controller.flow.favourites)
        #expect(requests == 0)
    }

    @Test("Display optical size remains independent of onboarding magnification")
    func opticalSize() throws {
        let textFont = BrandFonts.onboardingBody(19.74, weight: .semibold)
        let textAxes = try #require(CTFontCopyVariation(textFont as CTFont) as? [NSNumber: NSNumber])
        #expect(textAxes[NSNumber(value: 1_869_640_570)]?.intValue == 14)
        #expect(textAxes[NSNumber(value: 2_003_265_652)]?.intValue == 600)
        let font = BrandFonts.display(63.16, opticalSize: 40)
        let axes = try #require(CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber])
        #expect(abs(try #require(axes[NSNumber(value: 1_869_640_570)]).doubleValue - 40) < 0.01)
        let defaults = try #require(CTFontCopyVariationAxes(font as CTFont) as? [[String: Any]])
        let weight = try #require(defaults.first { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue == 2_003_265_652 })
        let defaultWeight = try #require(weight[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)
        #expect((axes[NSNumber(value: 2_003_265_652)] ?? defaultWeight).intValue == 800)
    }
}

extension OnboardingPresentationTests {
    @Test("Every card step keeps the primary footer attached with visible bounds")
    func footerGeometry() throws {
        for step in [BrowserOnboardingRecord.Step.favourites, .sync, .defaultBrowser] {
            let flow = OrbitOnboardingFlow(step: step, sources: [], syncAvailability: .available)
            let controller = OrbitOnboardingWindowController(flow: flow, services: .init(), themeTarget: nil)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let button = controller.card.primaryButton
            #expect(button.superview === controller.card.page)
            #expect(!button.isHidden && button.alphaValue > 0)
            #expect(button.frame.minY >= 600 && button.frame.maxY <= 714)
            #expect(button.acceptsFirstResponder == button.isEnabled)
            #expect(button.accessibilityRole() == .button)
        }
    }
}
