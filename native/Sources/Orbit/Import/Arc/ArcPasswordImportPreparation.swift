import AppKit
import BrowserCore
import CryptoKit
import Foundation

/// No source Keychain access at startup. This entry point is called only after an import action.
enum ArcPasswordImportPreparation {
    static func keys(_ configuration: OrbitProductConfiguration) -> any ArcSiteSessionKeyProviding {
        switch configuration.secureStorage {
        case .mockKeychain: return ArcSiteSessionFixtureKeys(dataRoot: configuration.dataRoot)
        case .keychain(let service, let account): return ArcSiteSessionKeychain(targetService: service, targetAccount: account)
        }
    }
    static func key(_ configuration: OrbitProductConfiguration, prepare: Bool = false) throws -> SymmetricKey {
        if let guardRoot = configuration.syntheticGuard {
            try guardRoot.checkRoot()
            return try ArcPasswordImportKey.fixture(root: configuration.dataRoot, prepare: prepare)
        }
        let product: OrbitNativeRecoveryKeyProvider.Product
        switch configuration.secureStorage {
        case .mockKeychain: throw BrowserAuthenticationImportError.invalidState
        case .keychain(let service, _): product = service == "Orbit Live Safe Storage" ? .live : .daily
        }
        return try ArcPasswordImportKey.key(root: configuration.dataRoot, product: product,
            backend: OrbitSystemRecoverySecItems(), prepare: prepare)
    }
    static func prepare(_ request: ArcSiteSessionRequest, configuration: OrbitProductConfiguration,
                        keys: any ArcSiteSessionKeyProviding, probe: any ArcRunningProbe) throws -> ArcPasswordImportJournal {
        if configuration.usesMockKeychain {
            try SyntheticDataGuard(syntheticRoot: request.sourceRoot, personalLocations: configuration.personalLocations).checkRoot()
        }
        var source = try keys.sourcePassword()
        defer { source.resetBytes(in: 0..<source.count) }
        let sourceProbe: any ArcRunningProbe = configuration.usesMockKeychain ? probe : SourceProbe()
        let read = try ArcPasswordImportSource.read(root: request.sourceRoot, profiles: request.profiles, sourcePassword: source, probe: sourceProbe)
        var target = try keys.targetPassword()
        defer { target.resetBytes(in: 0..<target.count) }
        return try ArcPasswordImportJournal.create(root: configuration.dataRoot, key: key(configuration, prepare: true),
            groups: read.groups, skipped: read.skipped, sourcePassword: source, targetPassword: target)
    }
    private struct SourceProbe: ArcRunningProbe {
        func isArcRunning(sourceRoot: URL) -> Bool {
            ArcSystemRunningProbe().isArcRunning(sourceRoot: sourceRoot.deletingLastPathComponent())
        }
    }
    static func open(_ id: UUID, configuration: OrbitProductConfiguration) throws -> ArcPasswordImportJournal {
        let journal = try ArcPasswordImportJournal.open(root: configuration.dataRoot, key: key(configuration), id: id)
        journal.checkpoint = { try ChromiumImportRecoveryProbe.checkpoint($0, configuration: configuration) }
        return journal
    }
}
