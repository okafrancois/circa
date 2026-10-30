import AppKit
import QuartzCore
import BrowserCore
import BrowserShell

/// Holds the first-run surface until its offline preparation can hand control to the engine.
@MainActor
enum OrbitOnboardingStartup {
    private static let quitDelegate = OrbitOnboardingQuitDelegate()
    static var cover: OrbitOnboardingWindowController?

    static func shouldRun(configuration: OrbitProductConfiguration, engineRootHadData: Bool) -> Bool {
        guard OrbitApplication.onboardingAdmitted(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments,
            hasSessionFile: true, synthetic: configuration.usesMockKeychain) else { return false }
        do {
            let record = try BrowserOnboardingFiles.load(dataDirectory: configuration.dataRoot)
            let fresh = BrowserOnboardingEligibility.isFresh(sessionFile: configuration.sessionFile, engineRootHadData: engineRootHadData)
            if case let .show(step, _) = BrowserOnboardingDecision.decide(admitted: true, record: record, fresh: fresh) { return step != .finish || record?.importApplied == true }
        } catch { return false }
        return false
    }

    static func run(configuration: OrbitProductConfiguration, engineRootHadData: Bool) throws {
        let admitted = OrbitApplication.onboardingAdmitted(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments,
            hasSessionFile: true, synthetic: configuration.usesMockKeychain)
        guard admitted else { return }
        let record = try BrowserOnboardingFiles.load(dataDirectory: configuration.dataRoot)
        let fresh = BrowserOnboardingEligibility.isFresh(sessionFile: configuration.sessionFile, engineRootHadData: engineRootHadData)
        guard case let .show(step, _) = BrowserOnboardingDecision.decide(admitted: admitted, record: record, fresh: fresh), step != .finish else { return }
        _ = (NSClassFromString("ACRApplication") as? NSApplication.Type)?.shared
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.delegate = quitDelegate
        defer { NSApplication.shared.delegate = nil }
        NSApplication.shared.finishLaunching()
        let menu = NSMenu()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: uiText("Quit Circa"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let applicationItem = NSMenuItem()
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApplication.shared.mainMenu = menu
        var ready = false
        var failure: Error?
        Task { @MainActor in
            do {
                let helper = OrbitApplication()
                let sources = await helper.onboardingSources(synthetic: configuration.usesMockKeychain)
                let availability: OrbitOnboardingSyncAvailability
                if configuration.usesMockKeychain { availability = OrbitOnboardingSyntheticSeam.syncAvailability }
                else if !BrowserSyncEntitlement.isAvailable() { availability = .unavailable }
                else { availability = FileManager.default.ubiquityIdentityToken == nil ? .signedOut : .available }
                let flow = OrbitOnboardingFlow(step: step, sources: sources, syncAvailability: availability, restoring: record)
                let store = try loadStore(configuration.sessionFile)
                var catalog = await store.catalogSnapshot()
                if catalog.profiles.isEmpty {
                    let profile = await store.createProfile(name: uiText("Personal"))
                    _ = try await store.createSpace(name: uiText("Space"), profileID: profile)
                    catalog = await store.catalogSnapshot()
                }
                guard let space = catalog.spaces.first else { throw BrowserSessionError.spaceMissing }
                let themeTarget = OrbitOnboardingThemeTarget(spaceID: space.id, profileID: space.profileID, stored: space.theme, commit: { theme in
                    try await store.setSpaceTheme(theme, for: space.id, profileID: space.profileID)
                    try BrowserSessionFileStore().save(await store.sessionDocument(), to: configuration.sessionFile)
                }, registry: nil)
                let preparation = OrbitOnboardingImportPreparation()
                var services = OrbitOnboardingServices()
                services.waitsForBrowserPreview = true
                services.persist = { record in try? BrowserOnboardingFiles.save(record, dataDirectory: configuration.dataRoot) }
                services.sourceArtwork = { OrbitOnboardingArtwork.artwork(for: $0, synthetic: configuration.usesMockKeychain) }
                services.loadFavourites = { try await preparation.favourites($0, configuration: configuration) }
                services.prepareFinish = { flow in
                    // Persist the initial theme before the importer opens its exclusive target.
                    if !flow.importApplied { try BrowserSessionFileStore().save(await store.sessionDocument(), to: configuration.sessionFile) }
                    let duration = flow.importApplied ? flow.importDuration : try await preparation.apply(flow, configuration: configuration)
                    var applied = flow.record(.started)
                    applied.importApplied = true; applied.importDuration = duration
                    applied.importSummary = try preparation.summary(configuration: configuration)
                    try BrowserOnboardingFiles.save(applied, dataDirectory: configuration.dataRoot)
                    let imported = try loadStore(configuration.sessionFile)
                    if !flow.skippedSteps.contains(.favourites), !flow.favouritesSkipped {
                        try await imported.addOnboardingFavourites(flow.favourites)
                    }
                    let importedCatalog = await imported.catalogSnapshot()
                    let firstSpace = flow.selectedSource == nil ? importedCatalog.spaces.first
                        : importedCatalog.spaces.first(where: { $0.id != space.id }) ?? importedCatalog.spaces.first
                    if let firstSpace {
                        if !flow.skippedSteps.contains(.theme), flow.selectedSource != nil {
                            let chosen = await store.catalogSnapshot().spaces.first(where: { $0.id == space.id })?.theme
                            try await imported.setSpaceTheme(chosen, for: firstSpace.id, profileID: firstSpace.profileID)
                        }
                        if await imported.sessionDocument().windows.isEmpty {
                            _ = try await imported.createWindow(activeSpaceID: firstSpace.id)
                        }
                    }
                    try BrowserSessionFileStore().save(await imported.sessionDocument(), to: configuration.sessionFile)
                    return duration
                }
                services.importSummary = { (try? BrowserOnboardingFiles.load(dataDirectory: configuration.dataRoot))?.importSummary }
                services.isDefaultBrowser = { configuration.usesMockKeychain ? nil : BrowserDefaultBrowserService().status().isOrbit }
                services.requestDefaultBrowser = {
                    if configuration.usesMockKeychain {
                        OrbitOnboardingSyntheticSeam.record("defaultBrowser", dataDirectory: configuration.dataRoot)
                    } else {
                        let service = BrowserDefaultBrowserService()
                        if service.canRequest() { try? await service.request() }
                    }
                }
                services.enteredFinish = { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + (OrbitMotionPreferences.prefersReducedMotion ? 0.27 : 0.57)) {
                        CATransaction.flush()
                        ready = true
                    }
                }
                let controller = OrbitOnboardingWindowController(flow: flow, services: services, themeTarget: themeTarget)
                cover = controller
                controller.present()
            } catch { failure = error; ready = true }
        }
        while !ready {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            NSApplication.shared.updateWindows()
        }
        if let failure { throw failure }
    }

    private static func loadStore(_ session: URL) throws -> BrowserStore {
        if FileManager.default.fileExists(atPath: session.path) { return try BrowserStore(restoring: BrowserSessionFileStore().load(from: session)) }
        return BrowserStore()
    }
}

/// No engine exists yet to service a runtime quit. The last step record was written atomically;
/// an interrupted import is recovered by the existing launch gate before any profile opens.
@MainActor
private final class OrbitOnboardingQuitDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        exit(0)
    }
}
