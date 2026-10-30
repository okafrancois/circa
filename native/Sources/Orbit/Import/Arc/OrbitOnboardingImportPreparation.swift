import AppKit
import BrowserCore

/// The same adapters and closed-runtime transaction used by the explicit import command.
@MainActor
final class OrbitOnboardingImportPreparation {
    func summary(configuration: OrbitProductConfiguration) throws -> BrowserOnboardingRecord.ImportSummary? {
        let location = ArcImportDataLocation(sessionFile: configuration.sessionFile)
        guard let bytes = try? Data(contentsOf: location.ledgerFile) else { return nil }
        let ledger = try JSONDecoder().decode(BrowserImportLedger.self, from: bytes)
        let profileIDs = Set(ledger.profileMappings.values.map { ProfileID($0) } + Array(ledger.profileTargets.values))
        let document = try BrowserSessionFileStore().load(from: configuration.sessionFile)
        let spaces = Set(document.spaces.filter { profileIDs.contains($0.profileID) }.map(\.id))
        let folders = Dictionary(uniqueKeysWithValues: document.organization.folders.map { ($0.id, $0.children) })
        let splits = Dictionary(uniqueKeysWithValues: document.organization.splits.map { ($0.id, $0.tabIDs) })
        func count(_ nodes: [BrowserOrganizationNode]) -> Int {
            nodes.reduce(0) { total, node in
                switch node {
                case .tab: return total + 1
                case let .folder(id): return total + count(folders[id] ?? [])
                case let .split(id): return total + (splits[id]?.count ?? 0)
                }
            }
        }
        let pinned = document.organization.spaces.filter { spaces.contains($0.spaceID) }.reduce(0) { $0 + count($1.pinned) }
        let passwords = try BrowserAuthenticationRun.exists(dataRoot: configuration.dataRoot)
            ? BrowserAuthenticationRun.open(dataRoot: configuration.dataRoot, recoveryKey: ChromiumAuthenticationStartup.recoveryKey(configuration)).status.passwords : 0
        return .init(spaces: spaces.count, pinnedTabs: pinned, passwords: passwords)
    }

    /// A refused source key does not invalidate the structural import already committed above.
    /// Filesystem/rollback failures still propagate so runtime cannot open a partial profile.
    static func importConnections(_ request: ArcSiteSessionRequest, dataRoot: URL,
                                  keys: sending any ArcSiteSessionKeyProviding,
                                  unavailable: @MainActor () -> Void) async throws {
        do {
            _ = try await Task.detached { try ArcSiteSessionImport(dataRoot: dataRoot).run(request, keys: keys) }.value
        } catch ArcAuthenticationError.sourceKeyUnavailable {
            unavailable()
        }
    }

    private var selectedExport: BrowserImportChoice?
    private var installationID = UUID()
    private var externalProfiles: [String: URL] = [:]

    private func choice(_ flow: OrbitOnboardingFlow, configuration: OrbitProductConfiguration) async throws -> BrowserImportChoice? {
        guard case let .browser(id, directory) = flow.importChoice else { return nil }
        if id == OrbitApplication.onboardingArcSourceID { return nil }
        if let selectedExport, selectedExport.descriptor.id == id { return selectedExport }
        let choices = try await BrowserImportCoordinator.inventory(configuration)
        guard var choice = choices.first(where: { $0.descriptor.id == id && $0.profile?.directory == directory }) else { throw ArcImportError.sourceNotFound }
        if choice.isSafari {
            let picker = BrowserImportPicker()
            guard let file = picker.chooseFile(zip: true) else { throw CancellationError() }
            if configuration.usesMockKeychain { try BrowserImportUISynthetic.checkSource(file, configuration: configuration) }
            let adapter = SafariBrowserImportAdapter(installationID: installationID, profile: .init(directory: "Default", name: ""), placement: .init(importedSpace: "", bookmarkFolder: "", windowName: ""), includeSharedData: true)
            let profiles = try await Task.detached {
                let snapshot = try adapter.snapshot(source: file, parent: FileManager.default.temporaryDirectory, probe: BrowserImportRunningProbe(running: { false }), diskSpace: OrbitSystemDiskSpaceProbe())
                defer { snapshot.remove() }
                return try adapter.discoverProfiles(metadata: SafariBrowserImportAdapter.inventoryData(snapshot: snapshot))
            }.value
            guard let selected = picker.choose(profiles.map { .init(descriptor: choice.descriptor, root: file, profile: $0) }, exportProfile: true) else { throw CancellationError() }
            choice = selected; selectedExport = selected
        }
        return choice
    }

    private func choices(_ flow: OrbitOnboardingFlow, configuration: OrbitProductConfiguration) async throws -> [BrowserImportChoice] {
        guard let primary = try await choice(flow, configuration: configuration) else { return [] }
        if primary.isSafari { return [primary] }
        let inventory = try await BrowserImportCoordinator.inventory(configuration)
        let selected = inventory.filter { $0.descriptor.id == primary.descriptor.id && $0.profile.map { flow.selectedProfiles.contains($0.directory) } == true }
        guard !selected.isEmpty, selected.count == flow.selectedProfiles.count else { throw ArcImportError.sourceNotFound }
        for choice in selected {
            guard let profile = choice.profile, profile.directory.hasPrefix("/"), externalProfiles[profile.directory] == nil else { continue }
            guard choice.isFirefox else { throw ArcImportError.unsupportedSourceFile }
            if configuration.usesMockKeychain {
                try BrowserImportUISynthetic.checkDirectory(URL(fileURLWithPath: profile.directory), configuration: configuration)
            }
            guard let chosen = BrowserImportPicker().chooseExternalProfile(profile) else { throw CancellationError() }
            guard chosen.path == profile.directory else { throw ArcImportError.sourceNotFound }
            externalProfiles[profile.directory] = chosen
        }
        return selected
    }

    private func adapter(_ choice: BrowserImportChoice) throws -> any BrowserImportSourceAdapter {
        guard let profile = choice.profile else { throw ArcImportError.sourceNotFound }
        let placement = ChromiumImportDiscovery.placement(browser: choice.descriptor.name, profile: profile.name)
        if choice.isSafari { return SafariBrowserImportAdapter(installationID: installationID, profile: profile, placement: placement, includeSharedData: true) }
        if choice.isFirefox {
            return FirefoxBrowserImportAdapter(descriptor: choice.descriptor, installationID: installationID, profile: profile, placement: placement, authenticationConsent: true, externalProfileRoot: externalProfiles[profile.directory])
        }
        return ChromiumBrowserImportAdapter(descriptor: choice.descriptor, installationID: installationID, profile: profile, placement: placement)
    }

    func favourites(_ flow: OrbitOnboardingFlow, configuration: OrbitProductConfiguration) async throws -> [BrowserOnboardingFavourite] {
        let choices = try await choices(flow, configuration: configuration)
        var visits: [BrowserHistoryVisit] = []
        for choice in choices {
            let adapter = try adapter(choice)
            let running = !configuration.usesMockKeychain && !NSRunningApplication.runningApplications(withBundleIdentifier: choice.descriptor.bundleID).isEmpty
            visits += try await Task.detached {
                let snapshot = try adapter.snapshot(source: choice.root, parent: FileManager.default.temporaryDirectory, probe: BrowserImportRunningProbe(running: { running }), diskSpace: OrbitSystemDiskSpaceProbe())
                defer { snapshot.remove() }
                var rows: [BrowserHistoryVisit] = []
                for (directory, file) in snapshot.historyDatabases {
                    let reader = try adapter.historyReader(file: file, directory: directory)
                    while let chunk = try reader.nextChunk(size: 2_000) { rows += chunk }
                }
                return rows
            }.value
        }
        return BrowserOnboardingFavourite.mostVisited(visits)
    }

    func apply(_ flow: OrbitOnboardingFlow, configuration: OrbitProductConfiguration) async throws -> Double? {
        guard let source = flow.selectedSource else { return nil }
        let started = ContinuousClock.now
        if source.id == OrbitApplication.onboardingArcSourceID {
            let sourceRoot = OrbitImportLaunchOptions.source(CommandLine.arguments)
            var options = ArcImportOptions()
            options.selectedProfileDirectories = flow.selectedProfiles.isEmpty ? nil : flow.selectedProfiles
            let importer = BrowserImportOrchestrator(source: sourceRoot, options: options, probe: BrowserImportRunningProbe(running: {
                !configuration.usesMockKeychain && !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier ?? "").isEmpty
            }))
            let target = try ArcOfflineImportTarget(sessionFile: configuration.sessionFile, usage: ImportRecoveryAlert.OfflineUsage(), separatedFrom: sourceRoot)
            do {
                let preparation = try await Task.detached { try await importer.prepare(for: target) }.value
                defer { preparation.discard() }
                _ = try await Task.detached { try await importer.apply(preparation, to: target) }.value
                await target.close()
            } catch { await target.close(); throw error }
            let ledger = try JSONDecoder().decode(BrowserImportLedger.self, from: Data(contentsOf: ArcImportDataLocation(sessionFile: configuration.sessionFile).ledgerFile))
            let pairs = ledger.profileTargets.compactMap { key, id -> ArcSiteSessionProfile? in
                guard let directory = key.directory else { return nil }
                return .init(sourceDirectory: directory, targetID: id)
            }
            if !pairs.isEmpty {
                let keys = ArcPasswordImportPreparation.keys(configuration)
                var request = ArcSiteSessionRequest(sourceRoot: sourceRoot.appendingPathComponent("User Data"), profiles: pairs)
                do {
                    let running = !configuration.usesMockKeychain && !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier ?? "").isEmpty
                    let preparedRequest = request
                    let journal = try await Task.detached {
                        try ArcPasswordImportPreparation.prepare(preparedRequest, configuration: configuration, keys: keys,
                            probe: BrowserImportRunningProbe(running: { running }))
                    }.value
                    request.passwordJobID = journal.id
                    try await Self.importConnections(request, dataRoot: configuration.dataRoot, keys: journal.connectionKeys()) {
                        ArcSiteSessionAlerts.show(nil, failed: true)
                    }
                    try journal.clearConnectionKeys()
                    try journal.activate()
                } catch ArcAuthenticationError.sourceKeyUnavailable { ArcSiteSessionAlerts.show(nil, failed: true) }
            }
        } else {
            let choices = try await choices(flow, configuration: configuration)
            guard let first = choices.first else { throw ArcImportError.sourceNotFound }
            let firstAdapter = try adapter(first)
            let running = !configuration.usesMockKeychain && !NSRunningApplication.runningApplications(withBundleIdentifier: first.descriptor.bundleID).isEmpty
            let probe = BrowserImportRunningProbe(running: { running })
            var importer = BrowserImportOrchestrator(source: first.root, probe: probe)
            importer.adapter = firstAdapter
            let target = try ArcOfflineImportTarget(sessionFile: configuration.sessionFile, usage: ImportRecoveryAlert.OfflineUsage(), separatedFrom: first.root)
            var inputs: [BrowserAuthenticationRun.Input] = []
            var transferred = false
            defer { if !transferred { for index in inputs.indices { inputs[index].discard() } } }
            do {
                for choice in choices {
                    let adapter = try adapter(choice)
                    var passwordCSV: Data?
                    if choice.isFirefox {
                        let picker = BrowserImportPicker()
                        switch picker.passwordCSVChoice() {
                        case 0:
                            guard let file = picker.chooseFile(zip: false) else { throw CancellationError() }
                            if configuration.usesMockKeychain { try BrowserImportUISynthetic.checkSource(file, configuration: configuration) }
                            passwordCSV = try await Task.detached { try BrowserImportMetadata.readCSV(file) }.value
                        case 1: break
                        default: throw CancellationError()
                        }
                    }
                    defer { if let count = passwordCSV?.count { passwordCSV?.resetBytes(in: 0..<count) } }
                    var reader = BrowserImportOrchestrator(source: choice.root, probe: probe)
                    reader.adapter = adapter
                    let worker = reader
                    let preparation = try await Task.detached { try await worker.prepare(for: target) }.value
                    do {
                        let authentication = try await Task.detached { try BrowserImportOfflineJob.authenticate(configuration: configuration, source: choice.root, adapter: adapter, probe: probe) }.value
                        inputs.append(.init(preparation: preparation, adapter: adapter, consent: true,
                            authentication: authentication.snapshot, sourcePassword: authentication.sourcePassword,
                            targetPassword: authentication.targetPassword, passwordCSV: passwordCSV))
                    } catch { preparation.discard(); throw error }
                }
                await target.close()
            } catch { await target.close(); throw error }
            let elapsed = started.duration(to: .now).components
            let preparationSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let job = BrowserImportOfflineJob(configuration: configuration, importer: importer, preparation: inputs[0].preparation,
                adapter: firstAdapter, batch: inputs, elapsedBeforeApply: preparationSeconds)
            transferred = true
            try await Task.detached { try await job.run() }.value
            try? BrowserImportMetadata.removeResult(root: configuration.dataRoot)
        }
        let elapsed = started.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
