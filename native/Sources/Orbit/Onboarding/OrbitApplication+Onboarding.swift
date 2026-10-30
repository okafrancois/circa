import AppKit
import BrowserCore
import QuartzCore
import UniformTypeIdentifiers

/// Synthetic runs (mock Keychain, explicit `--offer-onboarding`) never reach iCloud or the system
/// default browser: their requests are appended to `onboarding-requests.jsonl` in the synthetic
/// data root, and `ORBIT_ONBOARDING_SYNC` (available, signedOut, unavailable) sets iCloud's state.
@MainActor
enum OrbitOnboardingSyntheticSeam {
    static var isActive: Bool {
        activeSyntheticDataGuard() != nil && ProcessInfo.processInfo.arguments.contains(OrbitApplication.onboardingOption)
    }

    static var syncAvailability: OrbitOnboardingSyncAvailability {
        switch ProcessInfo.processInfo.environment["ORBIT_ONBOARDING_SYNC"] {
        case "available": .available
        case "signedOut": .signedOut
        default: .unavailable
        }
    }

    static func record(_ request: String, value: Bool? = nil, dataDirectory: URL) {
        guard isActive, let confinement = activeSyntheticDataGuard() else { return }
        let file = dataDirectory.appendingPathComponent("onboarding-requests.jsonl")
        guard (try? confinement.checkInside(file)) != nil else { return }
        var line: [String: Any] = ["request": request]
        if let value { line["value"] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([10]))
    }
}

/// Browser icons and their tinted tiles on the import step.
@MainActor
enum OrbitOnboardingArtwork {
    /// Measured tile colours of the three browsers the design shows.
    static let measuredTints: [String: NSColor] = [
        "chrome": NSColor(srgbRed: 234 / 255, green: 212 / 255, blue: 155 / 255, alpha: 1),
        "firefox": NSColor(srgbRed: 243 / 255, green: 156 / 255, blue: 196 / 255, alpha: 1),
        "safari": NSColor(srgbRed: 202 / 255, green: 224 / 255, blue: 246 / 255, alpha: 1)
    ]

    static func artwork(for source: OrbitOnboardingSource, synthetic: Bool) -> (NSImage?, NSColor) {
        var icon: NSImage?
        // Synthetic runs never consult the installed browsers, not even for their icons.
        if !synthetic, let identifier = source.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        let image = icon ?? NSWorkspace.shared.icon(for: .applicationBundle)
        return (image, measuredTints[source.id] ?? derivedTint(image))
    }

    /// Other browsers: their icon's mean colour, 63 % toward white (the mean of the three measured
    /// tiles' lightening).
    static func derivedTint(_ image: NSImage) -> NSColor {
        var rect = NSRect(x: 0, y: 0, width: 16, height: 16)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return OrbitOnboardingColors.rightPanel }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let data = context.data else { return OrbitOnboardingColors.rightPanel }
        let pixels = data.bindMemory(to: UInt8.self, capacity: 16 * 16 * 4)
        var sum = [0.0, 0.0, 0.0], weight = 0.0
        for index in 0..<(16 * 16) {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            for channel in 0..<3 { sum[channel] += Double(pixels[index * 4 + channel]) / 255 / alpha }
            weight += 1
        }
        guard weight > 0 else { return OrbitOnboardingColors.rightPanel }
        let mean = sum.map { $0 / weight }
        func lighten(_ value: Double) -> CGFloat { CGFloat(1 - (1 - value) * 0.37) }
        return NSColor(srgbRed: lighten(mean[0]), green: lighten(mean[1]), blue: lighten(mean[2]), alpha: 1)
    }
}

extension OrbitApplication {
    /// Lab-only admission of a synthetic run; still subject to the empty-profile rule.
    static let onboardingOption = "--offer-onboarding"

    /// The product's default session, or a synthetic run that asks for it explicitly.
    static func onboardingAdmitted(bundleIdentifier: String?, arguments: [String], hasSessionFile: Bool,
                                   synthetic: Bool) -> Bool {
        guard hasSessionFile, !arguments.contains("--session-file"), !arguments.contains("--ephemeral") else { return false }
        if synthetic { return arguments.contains(onboardingOption) }
        return bundleIdentifier == ProductIdentity.bundleIdentifier
    }

    /// Decides once per launch, from the launch-time state of the data directory. Builds the
    /// onboarding window (not yet shown) when this launch shows it; main windows are then held.
    func prepareOnboarding() async {
        guard let environment, let sessionFile = environment.sessionFile else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let synthetic = activeSyntheticDataGuard() != nil
        guard Self.onboardingAdmitted(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: arguments,
                                      hasSessionFile: true, synthetic: synthetic) else { return }
        let dataDirectory = sessionFile.deletingLastPathComponent()
        var record: BrowserOnboardingRecord?
        var unreadable = false
        do { record = try BrowserOnboardingFiles.load(dataDirectory: dataDirectory) } catch { unreadable = true }
        let decision = BrowserOnboardingDecision.decide(admitted: true, record: record, recordUnreadable: unreadable,
                                                        fresh: environment.launchedOnFreshDataDirectory)
        guard case let .show(step, _) = decision, let context = try? await environment.initialContext.value else { return }
        let (spaceID, profileID) = context
        let stored = await environment.store.catalogSnapshot().spaces.first { $0.id == spaceID }?.theme
        let target = OrbitOnboardingThemeTarget(spaceID: spaceID, profileID: profileID, stored: stored, commit: { [weak environment] theme in
            guard let environment else { return }
            try await environment.store.setSpaceTheme(theme, for: spaceID, profileID: profileID)
            environment.scheduleSave()
        }, registry: environment.themeEditors)
        let flow = OrbitOnboardingFlow(step: step, sources: await onboardingSources(synthetic: synthetic),
                                       syncAvailability: onboardingSyncAvailability(), restoring: record)
        var services = OrbitOnboardingServices()
        services.persist = { record in try? BrowserOnboardingFiles.save(record, dataDirectory: dataDirectory) }
        services.setSync = { [weak environment] enabled in
            if OrbitOnboardingSyntheticSeam.isActive {
                OrbitOnboardingSyntheticSeam.record("sync", value: enabled, dataDirectory: dataDirectory)
                return
            }
            guard let environment, environment.sync.available, environment.sync.enabled != enabled else { return }
            try? await environment.sync.setEnabled(enabled)
        }
        services.requestDefaultBrowser = {
            if OrbitOnboardingSyntheticSeam.isActive {
                OrbitOnboardingSyntheticSeam.record("defaultBrowser", dataDirectory: dataDirectory)
                return
            }
            let service = BrowserDefaultBrowserService()
            guard service.canRequest() else { return }
            try? await service.request()
        }
        services.finish = { [weak self] record, controller in self?.completeOnboarding(record, controller: controller, dataDirectory: dataDirectory) }
        services.sourceArtwork = { source in OrbitOnboardingArtwork.artwork(for: source, synthetic: synthetic) }
        onboarding = OrbitOnboardingWindowController(flow: flow, services: services, themeTarget: target)
    }

    func onboardingSyncAvailability() -> OrbitOnboardingSyncAvailability {
        if OrbitOnboardingSyntheticSeam.isActive { return OrbitOnboardingSyntheticSeam.syncAvailability }
        guard let environment, environment.sync.available else { return .unavailable }
        return FileManager.default.ubiquityIdentityToken == nil ? .signedOut : .available
    }

    /// Holds a routed main window while the onboarding is up; shown at the hand-off.
    func holdsWindowForOnboarding(_ controller: OrbitWindowController) -> Bool {
        guard onboarding != nil else { return false }
        heldOnboardingWindows.append(controller)
        return true
    }

    /// The main window takes the onboarding window's frame and first draws below it; the swap is
    /// then one transaction (measured hand-off: within one frame). The chosen import starts after.
    func completeOnboarding(_ record: BrowserOnboardingRecord, controller: OrbitOnboardingWindowController, dataDirectory: URL) {
        try? BrowserOnboardingFiles.save(record, dataDirectory: dataDirectory)
        let frame = controller.window?.frame
        onboarding = nil
        let held = heldOnboardingWindows
        heldOnboardingWindows = []
        var staged = false
        if let first = held.first, let frame, let window = first.window {
            window.setFrame(frame, display: false)
            first.windowedFrame = frame
            if let cover = controller.window, cover.isVisible {
                window.order(.below, relativeTo: cover.windowNumber)
                staged = true
            }
            window.displayIfNeeded()
        }
        let swap = { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            for (index, window) in held.enumerated() {
                presentAndScheduleUpdates { windowPresenter(window, index == 0) }
            }
            controller.window?.orderOut(nil)
            CATransaction.commit()
            controller.close()
            if held.isEmpty, windows.windows.isEmpty, !windows.hasPendingWindow { windows.newWindow() }
            finishExternalURLStartup()
            onOnboardingFinished?(record)
            startOnboardingImport(record.importChoice)
        }
        // A window that has never been on screen needs a few frames for its first render.
        if staged { DispatchQueue.main.asyncAfter(deadline: .now() + Self.handOffStaging) { MainActor.assumeIsolated { swap() } } }
        else { swap() }
    }

    static let handOffStaging: TimeInterval = 0.12
}
