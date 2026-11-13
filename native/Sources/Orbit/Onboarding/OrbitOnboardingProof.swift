import AppKit
import BrowserCore
import BrowserShell

/// An opt-in, confined first-run exercise. It never reads installed browser data or system storage.
@MainActor
enum OrbitOnboardingProof {
    private enum Failure: Error { case state(String), ownership, timeout }

    static func start(_ controller: OrbitOnboardingWindowController, configuration: OrbitProductConfiguration,
                      icons: FavoriteIconStore, profileID: ProfileID) {
        let arguments = ProcessInfo.processInfo.arguments
        guard configuration.usesMockKeychain, OrbitOnboardingSyntheticSeam.isActive,
              arguments.contains("--orbit-proof-onboarding"), let confinement = activeSyntheticDataGuard() else { return }
        let index = arguments.first { $0.hasPrefix("--orbit-proof-planet=") }
            .flatMap { Int($0.split(separator: "=", maxSplits: 1).last ?? "") } ?? 0
        guard (0..<4).contains(index) else { return }
        let output = configuration.dataRoot.appendingPathComponent("onboarding-proof", isDirectory: true)
        guard (try? confinement.checkInside(output)) != nil else { return }
        NSApp.appearance = NSAppearance(named: OrbitAppearance.launchOverride ?? .aqua)
        Task { @MainActor in
            var result: [String: Any] = ["planetIndex": index, "appearance": OrbitAppearance.launchOverride == .darkAqua ? "night" : "day"]
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try await step(.welcome, controller)
                try await press(controller.welcome.button)
                try await step(.importSource, controller)
                guard controller.flow.sources.isEmpty, controller.card.skipButton.isHidden,
                      controller.card.primaryButton.title == OrbitOnboardingText.next else { throw Failure.state("empty-import") }
                try await capture(controller.window, to: output.appendingPathComponent("import-empty.png"))
                try await press(controller.card.primaryButton)
                try await step(.favourites, controller)
                if index == 3, OrbitAppearance.launchOverride != .darkAqua {
                    guard let grid = controller.card.rightView?.subviews.compactMap({ $0 as? OrbitOnboardingFavouritesView }).first else { throw Failure.state("favourites") }
                    try await wait(22) { grid.icons.count == controller.flow.favourites.count }
                    let tiles = grid.subviews.compactMap { $0 as? NSButton }
                    guard controller.flow.favourites.enumerated().allSatisfy({ pair in
                        tiles.contains { $0.tag == pair.offset && $0.toolTip == pair.element.title && $0.accessibilityLabel() == pair.element.title }
                    }) else { throw Failure.state("favourite-accessibility") }
                    var fetched: [[String: String]] = []
                    for site in controller.flow.favourites {
                        guard let image = await icons.cachedImage(profile: profileID, home: site.url) else { throw Failure.state("favicon-cache") }
                        fetched.append(["title": site.title, "source": image.sourceURL.absoluteString])
                    }
                    result["favicons"] = fetched
                    guard let fourth = tiles.first(where: { $0.tag == 3 }) else { throw Failure.state("fourth-favourite") }
                    try await press(fourth)
                    try await capture(controller.window, to: output.appendingPathComponent("favourites-online.png"))
                }
                try await press(controller.card.skipButton)
                try await step(.sync, controller)
                try await press(controller.optionCards[1])
                try await press(controller.card.primaryButton)
                try await step(.theme, controller)
                guard let planet = controller.card.rightView?.subviews.compactMap({ $0 as? OrbitOnboardingPlanetButton }).first(where: { $0.planetIndex == index }) else { throw Failure.state("planet-picker") }
                try await press(planet)
                try await press(controller.card.primaryButton)
                try await step(.defaultBrowser, controller)
                try await press(controller.optionCards[1])
                try await press(controller.card.primaryButton)
                try await step(.finish, controller)
                try await wait(20) { controller.finishStage.button.isEnabled }
                try await Task.sleep(for: .seconds(2))
                try await press(controller.finishStage.button)
                try await wait(15) {
                    NSApp.windows.contains { $0.isVisible && $0.windowController is OrbitWindowController }
                }
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.windowController is OrbitWindowController }),
                      let browser = window.windowController as? OrbitWindowController else { throw Failure.state("browser-window") }
                await browser.session.waitForPendingCommands()
                try await Task.sleep(for: .milliseconds(500))
                let document = try BrowserSessionFileStore().load(from: configuration.sessionFile)
                let settings = try BrowserSettingsStore(destination: configuration.sessionFile.appendingPathExtension("settings.json"))
                let preferences = await settings.snapshot()
                let preset = BrandPalette.spaceGradients[index]
                let expected = BrowserSpaceIcon.planet(BrowserSpacePlanet.selectable[index])
                guard let space = document.spaces.first, space.name == OrbitOnboardingFirstSpace.name,
                      space.theme == preset.theme(), preferences.space(space.id).iconSelection == expected,
                      browser.sidebar.page.iconSelection == expected,
                      browser.sidebar.footer.spaceButtons.first?.iconSelection == expected,
                      browser.sidebar.spaceTitles == [OrbitOnboardingFirstSpace.name],
                      !OrbitAppearance.isDark(window.effectiveAppearance) else { throw Failure.state("first-space") }
                result["spaceName"] = space.name
                result["preset"] = preset.id
                result["headerAndFooterPlanet"] = BrowserSpacePlanet.selectable[index].rawValue
                result["daylightChrome"] = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
                try await capture(window, to: output.appendingPathComponent("main.png"))
                result["success"] = true
            } catch {
                result["success"] = false
                result["failure"] = String(describing: error)
            }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("result.json"), options: .atomic)
            }
            exit(result["success"] as? Bool == true ? 0 : 1)
        }
    }

    private static func wait(_ seconds: Double, _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition() {
            guard ContinuousClock.now < end else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func step(_ step: BrowserOnboardingRecord.Step, _ controller: OrbitOnboardingWindowController) async throws {
        try await wait(15) { controller.step == step && !controller.isTransitioning }
    }

    private static func owns(_ window: NSWindow) -> Bool {
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
        return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
    }

    private static func press(_ view: NSView) async throws {
        guard let window = view.window else { throw Failure.ownership }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait(1) { window.isKeyWindow && owns(window) }
        guard owns(window), view.window === window else { throw Failure.ownership }
        if let button = view as? OrbitOnboardingPrimaryButton { button.performClick(nil) }
        else if let button = view as? NSButton { button.performClick(nil) }
        else if let choice = view as? OrbitOnboardingOptionCard { _ = choice.accessibilityPerformPress() }
        else { throw Failure.state("control") }
    }

    private static func capture(_ window: NSWindow?, to file: URL) async throws {
        guard let window else { throw Failure.ownership }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        guard owns(window) else { throw Failure.ownership }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.state("capture") }
    }
}
