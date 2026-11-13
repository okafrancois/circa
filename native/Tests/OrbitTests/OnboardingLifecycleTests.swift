import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized) @MainActor
struct OnboardingLifecycleTests {
    private let entryKey = "orbit.onboarding.transform.translation.y"

    @Test("Engine adoption and repeated presentation preserve the finish entry's original timeline")
    func finishAdoption() async throws {
        var services = OrbitOnboardingServices()
        services.waitsForBrowserPreview = true
        let controller = OrbitOnboardingWindowController(flow: .init(step: .defaultBrowser, sources: [], syncAvailability: .unavailable), services: services, themeTarget: nil)
        controller.present()
        defer { controller.releaseBrowserPreview(); controller.window?.close() }
        controller.select(optionAt: 1)
        controller.primaryAction()
        for _ in 0..<200 where controller.step != .finish { await Task.yield() }
        #expect(controller.step == .finish)
        let title = controller.finishStage.title
        let began = try #require(title.layer?.animation(forKey: entryKey)?.beginTime)
        let moon = try #require(controller.finishStage.illustration.subviews.first)
        let moonBegan = try #require(moon.layer?.animation(forKey: entryKey)?.beginTime)
        #expect(!controller.finishStage.button.isEnabled)
        controller.primaryAction()
        #expect(!controller.isFinished, "Return cannot bypass browser readiness")
        try await Task.sleep(for: .milliseconds(80))
        let browser = OrbitBrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750), styleMask: [], backing: .buffered, defer: true)
        browser.isReleasedWhenClosed = false
        let browserContent = try #require(browser.contentView)
        controller.stageBrowserWindow(browser)
        controller.present()
        controller.render(direction: .forward, animated: true)
        #expect(title.layer?.animation(forKey: entryKey)?.beginTime == began)
        #expect(moon.layer?.animation(forKey: entryKey)?.beginTime == moonBegan)
        #expect(browserContent.isHidden && browserContent.superview === controller.window?.contentView)
        #expect(browserContent.layer?.animation(forKey: entryKey) == nil)
        #expect(controller.finishStage.button.isEnabled)
        controller.primaryAction()
        #expect(!browserContent.isHidden, "Only Open Circa reveals the prepared browser")
        controller.releaseBrowserPreview()
        #expect(browser.contentView === browserContent && !browserContent.isHidden)
    }

    @Test("A restored finish waits for its first presentation, then starts once")
    func restoredFinish() throws {
        let controller = OrbitOnboardingWindowController(flow: .init(step: .finish, sources: [], syncAvailability: .unavailable), services: .init(), themeTarget: nil)
        defer { controller.window?.close() }
        #expect(controller.finishStage.title.layer?.animation(forKey: entryKey) == nil)
        controller.present()
        let began = try #require(controller.finishStage.title.layer?.animation(forKey: entryKey)?.beginTime)
        controller.present()
        #expect(controller.finishStage.title.layer?.animation(forKey: entryKey)?.beginTime == began)
    }

    @Test("Readiness renders and repeated presentation retain each card and its entry animation")
    func cardRefreshes() throws {
        for step in [BrowserOnboardingRecord.Step.importSource, .favourites, .sync, .theme, .defaultBrowser] {
            let controller = OrbitOnboardingWindowController(flow: .init(step: step, sources: [], syncAvailability: .available), services: .init(), themeTarget: nil)
            defer { controller.window?.close() }
            controller.present()
            controller.card.playContents()
            let page = try #require(controller.card.page)
            let panel = controller.card.rightView
            let began = try #require(page.title.layer?.animation(forKey: entryKey)?.beginTime)
            controller.render(direction: .forward, animated: false)
            controller.present()
            #expect(controller.card.page === page && controller.card.rightView === panel)
            #expect(page.title.layer?.animation(forKey: entryKey)?.beginTime == began)
        }
    }

    @Test("Disabled footer links are visibly muted and reject direct action delivery")
    func disabledBack() {
        let finish = OrbitOnboardingFinishView(frame: .zero)
        var deliveries = 0
        finish.back.onPress = { deliveries += 1 }
        #expect(!finish.back.isEnabled && finish.back.textInk.alphaComponent == 0.35)
        _ = finish.back.sendAction(finish.back.action, to: finish.back.target)
        #expect(deliveries == 0)
        finish.back.isEnabled = true
        _ = finish.back.sendAction(finish.back.action, to: finish.back.target)
        #expect(deliveries == 1 && finish.back.textInk.alphaComponent == 1)
    }
}
}
