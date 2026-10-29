import AppKit
import BrowserCore

/// The live phase only prepares a private snapshot. Mutation belongs to the closed-runtime job.
@MainActor
final class BrowserImportCoordinator {
    private(set) var isRunning = false
    private let picker = BrowserImportPicker()
    private let progress = ArcImportAlertPresenter(browserImport: true)
    private var cancelCurrent: (() -> Void)?

    func start(application: OrbitApplication) {
        guard !isRunning, !application.orbitImport.isRunning, !application.isImportingSiteSessions,
              !application.isPreparingToQuit, application.pendingBrowserImport == nil,
              let configuration = activeSiteSessionConfiguration(), let environment = application.environment,
              let target = ArcImportLiveTarget(environment: environment),
              target.location.sessionFile == configuration.sessionFile else { NSSound.beep(); return }
        isRunning = true
        Task {
            defer { isRunning = false; progress.hideProgress(); cancelCurrent = nil }
            do {
                let choices: [BrowserImportChoice]
                if configuration.usesMockKeychain {
                    choices = try BrowserImportUISynthetic.choices(configuration)
                } else {
                    let descriptors = ChromiumImportDiscovery.installed() + ChromiumImportDiscovery.installedFirefoxFamily()
                        + NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.apple.Safari").prefix(1).map { _ in
                            SafariBrowserImportAdapter(installationID: UUID(), profile: .init(directory: "Default", name: ""),
                                placement: .init(importedSpace: "", bookmarkFolder: "", windowName: ""), includeSharedData: true).descriptor
                        }
                    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    choices = await Task.detached { BrowserImportInventory.choices(descriptors: descriptors, support: support) }.value
                }
                guard var choice = picker.choose(choices), picker.explain(choice) else { return }
                var csv: Data?
                if choice.isFirefox {
                    switch picker.passwordCSVChoice() {
                    case 0:
                        guard let file = picker.chooseFile(zip: false) else { return }
                        try configuration.syntheticGuard?.checkRoot()
                        if configuration.usesMockKeychain { try BrowserImportUISynthetic.checkSource(file, configuration: configuration) }
                        csv = try await Task.detached { try BrowserImportMetadata.readCSV(file) }.value
                    case 1: break
                    default: return
                    }
                }
                let installationID = UUID()
                var source = choice.root
                if choice.isSafari {
                    guard let file = picker.chooseFile(zip: true) else { return }
                    if configuration.usesMockKeychain { try BrowserImportUISynthetic.checkSource(file, configuration: configuration) }
                    source = file
                    let adapter = SafariBrowserImportAdapter(installationID: installationID, profile: .init(directory: "Default", name: ""),
                        placement: .init(importedSpace: "", bookmarkFolder: "", windowName: ""), includeSharedData: true)
                    let profiles = try await perform { _ in
                        let snapshot = try adapter.snapshot(source: file, parent: FileManager.default.temporaryDirectory,
                            probe: BrowserImportRunningProbe(running: { false }), diskSpace: OrbitSystemDiskSpaceProbe())
                        defer { snapshot.remove() }
                        return try adapter.discoverProfiles(metadata: SafariBrowserImportAdapter.inventoryData(snapshot: snapshot))
                    }
                    progress.hideProgress()
                    guard let selected = picker.choose(profiles.map { .init(descriptor: choice.descriptor, root: file, profile: $0) }, exportProfile: true) else { return }
                    choice = selected
                }
                guard let profile = choice.profile else { throw ArcImportError.sourceNotFound }
                var externalProfile: URL?
                if profile.directory.hasPrefix("/") {
                    guard choice.isFirefox else { throw ArcImportError.unsupportedSourceFile }
                    if configuration.usesMockKeychain {
                        try BrowserImportUISynthetic.checkDirectory(URL(fileURLWithPath: profile.directory), configuration: configuration)
                    }
                    guard let chosen = picker.chooseExternalProfile(profile) else { return }
                    guard chosen.path == profile.directory else { throw ArcImportError.sourceNotFound }
                    externalProfile = chosen
                }
                let placement = ChromiumImportDiscovery.placement(browser: choice.descriptor.name, profile: profile.name)
                let adapter: any BrowserImportSourceAdapter
                if choice.isSafari {
                    adapter = SafariBrowserImportAdapter(installationID: installationID, profile: profile, placement: placement, includeSharedData: true)
                } else if choice.isFirefox {
                    adapter = FirefoxBrowserImportAdapter(descriptor: choice.descriptor, installationID: installationID, profile: profile,
                        placement: placement, authenticationConsent: true, externalProfileRoot: externalProfile)
                } else {
                    adapter = ChromiumBrowserImportAdapter(descriptor: choice.descriptor, installationID: installationID, profile: profile, placement: placement)
                }
                let bundleID = choice.descriptor.bundleID
                let synthetic = configuration.usesMockKeychain
                let probe = BrowserImportRunningProbe(running: {
                    !synthetic && !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
                })
                var importer = BrowserImportOrchestrator(source: source, probe: probe)
                importer.adapter = adapter
                let preparedImporter = importer
                let reviewTarget = try BrowserImportReviewTarget(live: target, document: await environment.store.sessionDocument())
                let preparation = try await perform { update in try await preparedImporter.prepare(for: reviewTarget, progress: update) }
                var transferred = false
                defer { if !transferred { preparation.discard() } }
                progress.hideProgress()
                guard preparation.report.sessionBudget.fits else { throw ArcImportError.sessionTooLarge(projectedBytes: preparation.report.sessionBudget.projectedBytes, limitBytes: preparation.report.sessionBudget.limitBytes) }
                guard picker.confirm(title: uiFormat("Import from %@?", choice.descriptor.name),
                    message: BrowserImportText.review(preparation.report, passwordCSV: csv != nil), button: uiText("Import and Restart")) else { return }
                // This explicit Import action is the only source Keychain admission. Worker only.
                let selectedSource = source
                let authentication = try await perform { _ in
                    try BrowserImportOfflineJob.authenticate(configuration: configuration, source: selectedSource,
                        adapter: adapter, probe: probe)
                }
                application.pendingBrowserImport = BrowserImportOfflineJob(configuration: configuration, importer: importer,
                    preparation: preparation, adapter: adapter, authentication: authentication, passwordCSV: csv)
                transferred = true
                NSApp.terminate(nil)
            } catch {
                progress.hideProgress()
                if !(error is CancellationError), (error as? ArcImportError) != .cancelled { picker.failure(error) }
            }
        }
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable (@escaping @Sendable (ArcImportProgress) -> Void) async throws -> T) async throws -> T {
        let (stream, continuation) = AsyncStream.makeStream(of: ArcImportProgress.self, bufferingPolicy: .bufferingNewest(1))
        let delay = Bundle.main.bundleIdentifier == "lab.orbit.orbit.import-ui"
            && ProcessInfo.processInfo.environment["ORBIT_IMPORT_UI_PROGRESS_DELAY"] == "1"
        let task = Task.detached {
            defer { continuation.finish() }
            if delay { try await Task.sleep(for: .seconds(1)) }
            try Task.checkCancellation()
            return try await operation { continuation.yield($0) }
        }
        cancelCurrent = { task.cancel() }
        progress.showProgress(.init(.copying)) { task.cancel() }
        for await value in stream { progress.showProgress(value) { task.cancel() } }
        cancelCurrent = nil
        return try await task.value
    }
}
