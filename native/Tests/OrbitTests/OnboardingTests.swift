import AppKit
import BrowserCore
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

    @Test("Six steps; Next waits for a choice; Back only from sync to default browser; Skip only on the theme")
    func flow() {
        var flow = OrbitOnboardingFlow(sources: Self.sources, syncAvailability: .available)
        #expect(OrbitOnboardingFlow.steps == [.welcome, .importSource, .sync, .theme, .defaultBrowser, .finish])
        var moved = flow.advance()
        #expect(moved)
        #expect(flow.step == .importSource && !flow.canAdvance && !flow.hasBack)
        flow.select(source: Self.sources[1])
        #expect(flow.importChoice == .browser(sourceID: "chrome", profileDirectory: "Default"))
        flow.select(profile: "Profile 1", of: Self.sources[1])
        #expect(flow.importChoice == .browser(sourceID: "chrome", profileDirectory: "Profile 1"))
        flow.select(profile: "Missing", of: Self.sources[1])
        #expect(flow.importChoice == .browser(sourceID: "chrome", profileDirectory: "Profile 1"))
        moved = flow.advance()
        #expect(moved && flow.step == .sync && !flow.canAdvance && flow.hasBack)
        flow.selectSync(true)
        moved = flow.advance()
        #expect(moved && flow.step == .theme && flow.hasSkip && flow.canAdvance)
        moved = flow.goBack()
        #expect(moved && flow.step == .sync && flow.syncChoice == true)
        moved = flow.advance() && flow.advance()
        #expect(moved && flow.step == .defaultBrowser && !flow.canAdvance)
        flow.defaultBrowserChoice = false
        moved = flow.advance()
        #expect(moved && flow.step == .finish && !flow.hasBack)
        moved = flow.advance()
        #expect(!moved)
        let record = flow.record(.completed)
        #expect(record.state == .completed && record.step == .finish && record.syncChoice == true && record.defaultBrowserChoice == false)
        // Unavailable iCloud preselects "no" and refuses "yes"; no detected browser preselects "start fresh".
        var offline = OrbitOnboardingFlow(step: .sync, sources: [], syncAvailability: .signedOut)
        offline.selectSync(true)
        #expect(offline.syncChoice == false && offline.canAdvance)
        #expect(offline.importChoice == BrowserOnboardingRecord.ImportChoice.none)
        // A resumed record keeps only choices that are still offered.
        let resumed = OrbitOnboardingFlow(step: .theme, sources: [Self.sources[0]], syncAvailability: .available,
                                          restoring: BrowserOnboardingRecord(state: .started, step: .theme, importChoice: .browser(sourceID: "chrome", profileDirectory: "Default"), syncChoice: true))
        #expect(resumed.importChoice == nil && resumed.syncChoice == true && resumed.step == .theme)
    }

    @Test("Measured card layout: panel, perforation, title and body baselines, button, Skip and Back")
    func layout() throws {
        let (controller, _) = controller(step: .theme)
        let card = controller.card
        #expect(card.frame.size == M.cardSize)
        #expect(controller.window?.contentLayoutRect.size == M.windowSize || controller.window?.frame.size == M.windowSize)
        #expect(card.frame.minX == 157 && card.frame.minY == 126)
        #expect(controller.window?.animationBehavior == NSWindow.AnimationBehavior.none)
        // The measured backdrop: 128 keyframes (32 s at 4 per second), upsampled ×8.
        #expect(OrbitOnboardingBackgroundView.frames.count == OrbitOnboardingBackgroundData.frameCount)
        #expect(OrbitOnboardingBackgroundView.frames.first?.width == 128 && OrbitOnboardingBackgroundView.frames.first?.height == 80)
        #expect(controller.background.field.animation(forKey: OrbitOnboardingBackgroundView.animationKey)?.duration == 32)
        #expect(controller.window?.styleMask.contains(.resizable) == false)
        #expect(controller.window?.standardWindowButton(.closeButton) != nil)
        #expect(card.layer?.cornerRadius == M.cardCornerRadius)
        let edge = try #require(card.leftPanel.path).boundingBox
        #expect(abs(edge.maxX - (M.perforationCenterX + M.perforationAmplitude)) < 0.1)
        #expect(card.primaryButton.frame == NSRect(x: 50, y: 422, width: 256, height: 40))
        #expect(!card.skipButton.isHidden && card.backButton.alphaValue == 1)
        let skipBaseline = card.skipButton.frame.minY + (card.skipButton.frame.height + OrbitOnboardingFonts.skip.capHeight) / 2
        #expect(abs(skipBaseline - 494.4) < 0.5)
        let page = try #require(card.page)
        let titleCapTop = page.title.frame.minY + OrbitOnboardingTextPage.firstBaseline(of: page.title) - OrbitOnboardingFonts.title.capHeight
        #expect(abs(titleCapTop - M.titleCapTopWithBack) < 0.5)
        let (importing, _) = self.controller(step: .importSource)
        #expect(importing.card.primaryButton.frame == NSRect(x: 50, y: 458, width: 256, height: 40))
        #expect(importing.card.skipButton.isHidden && importing.card.backButton.alphaValue == 0)
        #expect(importing.optionCards.count == Self.sources.count + 1)
        #expect(importing.optionCards.first?.frame == NSRect(x: 168, y: M.importFirstRowTop, width: 274, height: 90))
        let (choices, _) = self.controller(step: .defaultBrowser)
        let yes = try #require(choices.optionCards.first), no = try #require(choices.optionCards.last)
        #expect(yes.frame.size == M.choiceCardSize && no.frame.minY - yes.frame.maxY == M.optionGap)
        #expect(abs((yes.frame.minY + no.frame.maxY) / 2 - M.cardSize.height / 2) < 0.01)
    }

    @Test("Next is disabled until a choice and dims its label; Return is its key equivalent")
    func primaryButton() throws {
        let (controller, recorder) = controller(step: .importSource)
        let button = controller.card.primaryButton
        #expect(!button.isEnabled && button.keyEquivalent == "\r")
        let label = button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(label?.alphaComponent == M.disabledLabelAlpha)
        controller.select(optionAt: 0)
        #expect(button.isEnabled)
        #expect(controller.flow.importChoice == .browser(sourceID: "brave", profileDirectory: nil))
        #expect(controller.optionCards[0].isSelected && !controller.optionCards[1].isSelected)
        #expect(recorder.records.isEmpty)
        #expect(controller.welcome.button.keyEquivalent == "\r")
    }

    @Test("A step change pushes 403 pt with the measured spring and cross-fades the right panel")
    func push() async throws {
        let (controller, recorder) = controller(step: .importSource)
        controller.select(optionAt: 1)
        controller.primaryAction()
        let layer = try #require(controller.card.page?.layer)
        let push = try #require(layer.animation(forKey: OrbitOnboardingCardView.pushKey) as? CASpringAnimation)
        #expect(push.keyPath == "transform.translation.x")
        #expect(push.fromValue as? CGFloat == M.pushDistance && push.toValue as? CGFloat == 0)
        // The incoming page is laid out (and drawn) inside the panel; only its layer is offset.
        #expect(controller.card.page?.frame.origin == .zero)
        #expect(abs(push.stiffness - pow(2 * .pi / 0.41, 2)) < 0.01)
        #expect(abs(push.damping - 4 * .pi * 0.82 / 0.41) < 0.01)
        #expect(push.mass == 1 && push.initialVelocity == 0)
        let fade = try #require(controller.card.rightView?.layer?.animation(forKey: OrbitOnboardingCardView.fadeKey) as? CABasicAnimation)
        #expect(fade.duration == 0.35 && fade.timingFunction == CAMediaTimingFunction(name: .easeInEaseOut))
        #expect(controller.step == .sync)
        #expect(recorder.records.last?.step == .sync && recorder.records.last?.state == .started)
        #expect(recorder.records.last?.importChoice == .browser(sourceID: "chrome", profileDirectory: "Default"))
        await settle(controller)
        controller.backAction()
        let back = try #require(controller.card.page?.layer?.animation(forKey: OrbitOnboardingCardView.pushKey) as? CASpringAnimation)
        #expect(back.fromValue as? CGFloat == -M.pushDistance && back.toValue as? CGFloat == 0)
        #expect(controller.step == .importSource)
    }

    @Test("Sync and default browser act on Next; finish hands over a completed record")
    func actions() async throws {
        let (controller, recorder) = controller(step: .sync)
        controller.select(optionAt: 0)
        controller.primaryAction()
        await settle(controller)
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.sync == [true])
        controller.skipAction()
        await settle(controller)
        #expect(controller.step == .defaultBrowser)
        controller.select(optionAt: 0)
        controller.primaryAction()
        await settle(controller)
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.defaultRequests == 1)
        #expect(controller.step == .finish && controller.card.primaryButton.title == OrbitOnboardingText.getStarted)
        controller.primaryAction()
        #expect(recorder.finished?.state == .completed && recorder.finished?.syncChoice == true)
        #expect(controller.isFinished)
        controller.primaryAction()
        #expect(recorder.records.filter { $0.state == .completed }.isEmpty)
        // "No" requests nothing.
        let (declining, declined) = self.controller(step: .defaultBrowser)
        declining.select(optionAt: 1)
        declining.primaryAction()
        try await Task.sleep(for: .milliseconds(20))
        #expect(declined.defaultRequests == 0)
        let (unavailable, _) = self.controller(step: .sync, sync: .unavailable)
        #expect(!unavailable.optionCards[0].isEnabled && unavailable.optionCards[1].isSelected && unavailable.card.primaryButton.isEnabled)
    }

    @Test("A theme pick recolours the backdrop, the panel and the accent in one transaction; Skip restores it")
    func theme() async throws {
        let (controller, recorder) = controller(step: .theme)
        let editor = try #require(controller.themeEditor)
        #expect(editor.view.surfaceScope.isHidden && editor.view.material.isHidden)
        let container = try #require(editor.view.superview?.superview)
        #expect(abs(container.frame.width - 294.4) < 0.01 && abs(container.frame.height - 420) < 0.2 && container.frame.minY == 64)
        #expect(abs(container.bounds.width - 356) < 0.01 && abs(container.bounds.height - 508) < 0.01)
        #expect(controller.background.themeFill.isHidden)
        let pick = BrowserSpaceTheme.radial(colors: [BrowserThemeColor(hex: 0x2DD48C)], intensity: BrowserSpaceTheme.defaultIntensity,
                                            noise: 0.3, mode: .light)
        editor.onPreview?(pick)
        #expect(!controller.background.themeFill.isHidden)
        #expect(controller.card.layer?.backgroundColor == OrbitOnboardingColors.rightPanelThemed.cgColor)
        let accent = try #require(controller.accent.usingColorSpace(.sRGB))
        func linear(_ c: CGFloat) -> Double { let v = Double(c); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(accent.redComponent) + 0.7152 * linear(accent.greenComponent) + 0.0722 * linear(accent.blueComponent)
        #expect(abs(luminance - 0.070) < 0.002)
        #expect(controller.card.primaryButton.layer?.backgroundColor == controller.accent.cgColor)
        controller.skipAction()
        #expect(controller.background.themeFill.isHidden && controller.step == .defaultBrowser)
        await settle(controller)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.committed.last == .some(nil))
        // The default theme keeps the measured default accent.
        #expect(OrbitOnboardingColors.accent(for: BrowserSpaceThemePresets.default) == OrbitOnboardingColors.accent)
    }

    @Test("VoiceOver: option cards are labelled radio buttons; lists are labelled groups")
    func accessibility() {
        let (controller, _) = controller(step: .importSource)
        controller.select(optionAt: 1)
        for card in controller.optionCards {
            #expect(card.accessibilityRole() == .radioButton)
            #expect(!(card.accessibilityLabel() ?? "").isEmpty)
        }
        #expect(controller.optionCards[1].accessibilityValue() as? Int == 1)
        #expect(controller.profileList?.accessibilityRole() == .radioGroup)
        #expect(controller.profileList?.rows.map { $0.accessibilityLabel() } == ["Personal", "Work", "Side Project"])
        #expect(controller.welcome.button.accessibilityLabel() == OrbitOnboardingText.getStarted)
        let (themed, _) = self.controller(step: .theme)
        #expect(themed.card.backButton.accessibilityRole() == .button && themed.card.backButton.accessibilityLabel() == OrbitOnboardingText.back)
        #expect(themed.card.skipButton.accessibilityLabel() == OrbitOnboardingText.skip)
        let (choices, _) = self.controller(step: .defaultBrowser)
        #expect(choices.optionCards.first?.accessibilityLabel() == OrbitOnboardingText.defaultYesStrong + " " + OrbitOnboardingText.defaultYes)
    }

    @Test("Hover scales an option card ×1.05 about its centre")
    func hover() {
        let (controller, _) = controller(step: .defaultBrowser)
        let card = controller.optionCards[0]
        card.setHovered(true)
        let transform = card.layer?.sublayerTransform ?? CATransform3DIdentity
        #expect(abs(transform.m11 - 1.05) < 0.0001 && abs(transform.m22 - 1.05) < 0.0001)
        card.setHovered(false)
        #expect(CATransform3DIsIdentity(card.layer?.sublayerTransform ?? CATransform3DIdentity))
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
