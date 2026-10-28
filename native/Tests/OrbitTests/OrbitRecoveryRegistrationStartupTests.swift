import BrowserCore
import Darwin
import Foundation
import Security
import Testing
@testable import Orbit

private final class StartupRegistrationStorage: OrbitRecoverySecItemBoundary {
    var rows: [[String: Any]] = []
    var reads = 0; var adds = 0
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        reads += 1
        let matches = rows.filter {
            $0[kSecAttrService as String] as? String == query[kSecAttrService as String] as? String &&
            $0[kSecAttrAccount as String] as? String == query[kSecAttrAccount as String] as? String
        }
        return matches.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, matches)
    }
    func add(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        adds += 1; var row = attributes; let reference = Data(UUID().uuidString.utf8)
        row[kSecValuePersistentRef as String] = reference; rows.append(row)
        return (errSecSuccess, reference)
    }
}

@Suite("Actual product load-only registration composition", .serialized)
struct OrbitRecoveryRegistrationStartupTests {
    private func prepare(_ root: URL) throws -> (OrbitProductConfiguration, OrbitDataRootLock) {
        try OrbitProductLaunch.prepare(arguments: ["Orbit", "--use-mock-keychain", "--orbit-data-root=" + root.path], infoDictionary: [:],
                                      applicationSupport: root.deletingLastPathComponent().appendingPathComponent("home/Library/Application Support"),
                                      build: OrbitBuildIdentity(bundleIdentifier: nil, signature: nil))
    }
    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("orbit-startup-registration-" + UUID().uuidString)
    }
    private func write(_ text: String, _ url: URL) throws {
        try Data(text.utf8).write(to: url); #expect(chmod(url.path, 0o600) == 0)
    }

    @Test func untouchedProductCompositionDoesNotConstructStorageOrRegistration() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try prepare(root); let storage = StartupRegistrationStorage()
        var factories = 0; var starts = 0
        try OrbitAuthenticationStartup.run(configuration: prepared.0, lock: prepared.1, backend: {
            factories += 1; return storage
        }) { starts += 1 }
        #expect(starts == 1 && factories == 0 && storage.reads == 0 && storage.adds == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains(where: { $0.hasPrefix(".orbit-auth") }))
    }

    @Test func preparedProductReopensRegisteredEvidenceUsingOnlyInjectedLoader() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StartupRegistrationStorage()
        let profile = root.appendingPathComponent("Chromium/profile-11111111-1111-1111-1111-111111111111")
        do {
            let prepared = try prepare(root); let lease = try #require(prepared.1.recoveryLease)
            try write("orbit-auth-recovery-synthetic-v1\n", root.appendingPathComponent(".orbit-auth-recovery-synthetic"))
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try write("invented-original", profile.appendingPathComponent("Cookies"))
            let registration = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily)
            let provider = try registration.syntheticKeyProvider(product: .daily, backend: storage)
            _ = try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: provider,
                                                                   profilePath: "Chromium/" + profile.lastPathComponent, deadline: 2000)
            try write("changed", profile.appendingPathComponent("Cookies"))
        }
        var starts = 0; var factories = 0
        do {
            let prepared = try prepare(root)
            try OrbitAuthenticationStartup.run(configuration: prepared.0, lock: prepared.1, backend: {
                factories += 1; return storage
            }, now: 1000) { starts += 1 }
        }
        let restored = try Data(contentsOf: profile.appendingPathComponent("Cookies")) == Data("invented-original".utf8)
        #expect(restored && starts == 1 && factories == 1 && storage.adds == 1)
        // The exact launcher default for synthetic mode refuses rather than using Security.
        let prepared = try prepare(root)
        #expect(throws: OrbitRecoveryFailure.keyUnavailable) {
            try OrbitAuthenticationStartup.run(configuration: prepared.0, lock: prepared.1, now: 1000) { starts += 1 }
        }
        #expect(starts == 1 && storage.adds == 1)
    }

    @Test func liveAuthorityUsesItsFixedRecoveryNamespaceAndUnknownAuthorityRefuses() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StartupRegistrationStorage()
        do {
            let prepared = try prepare(root); let lease = try #require(prepared.1.recoveryLease)
            try write("orbit-auth-recovery-synthetic-v1\n", root.appendingPathComponent(".orbit-auth-recovery-synthetic"))
            let profile = "Chromium/profile-11111111-1111-1111-1111-111111111111"
            try FileManager.default.createDirectory(at: root.appendingPathComponent(profile), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let registration = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .live)
            _ = try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease,
                provider: registration.syntheticKeyProvider(product: .live, backend: storage), profilePath: profile, deadline: 2000)
        }
        let prepared = try prepare(root)
        let live = OrbitProductConfiguration(dataRoot: root, secureStorage: .keychain(service: "Orbit Live Safe Storage", account: "Orbit Live"))
        var starts = 0
        try OrbitAuthenticationStartup.run(configuration: live, lock: prepared.1, backend: { storage }, now: 1000) { starts += 1 }
        let correctService = storage.rows.count == 1 && storage.rows[0][kSecAttrService as String] as? String == "Orbit Live Authentication Recovery v1"
        #expect(starts == 1 && correctService && storage.adds == 1)
        let unknown = OrbitProductConfiguration(dataRoot: root, secureStorage: .keychain(service: "unknown", account: "unknown"))
        let reads = storage.reads
        #expect(throws: OrbitRecoveryFailure.invalidEvidence) {
            try OrbitAuthenticationStartup.run(configuration: unknown, lock: prepared.1, backend: { storage }, now: 1000) { starts += 1 }
        }
        #expect(starts == 1 && storage.reads == reads && storage.adds == 1)
    }

    @Test func registeredPrivateRootModeIsRefusedBeforePreparationCanNormalizeIt() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            let prepared = try prepare(root); let lease = try #require(prepared.1.recoveryLease)
            try write("orbit-auth-recovery-synthetic-v1\n", root.appendingPathComponent(".orbit-auth-recovery-synthetic"))
            _ = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily)
        }
        #expect(chmod(root.path, 0o750) == 0)
        #expect(throws: (any Error).self) { try prepare(root) }
        var info = stat(); #expect(lstat(root.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o750)
    }

    @Test func incompleteEvidenceRefusesBeforeFactoryAndAllRuntimeHooks() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try prepare(root)
        try write("incomplete", root.appendingPathComponent(".orbit-auth-recovery-required"))
        var factories = 0; var starts = 0; let storage = StartupRegistrationStorage()
        #expect(throws: (any Error).self) {
            try OrbitAuthenticationStartup.run(configuration: prepared.0, lock: prepared.1, backend: {
                factories += 1; return storage
            }) { starts += 1 }
        }
        #expect(factories == 0 && starts == 0 && storage.reads == 0 && storage.adds == 0)
    }
}
