// Runtime-free process probe using the actual product preparation/startup sources.
// Fake persistence is exclusively the explicitly confined disposable sibling file.
import BrowserCore
import Darwin
import Foundation
import Security

private final class ProcessRegistrationStorage: OrbitRecoverySecItemBoundary {
    let file: URL
    let mayAdd: Bool
    var reads = 0
    var adds = 0
    init(file: URL, mayAdd: Bool) { self.file = file; self.mayAdd = mayAdd }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        reads += 1
        guard let bytes = try? Data(contentsOf: file),
              let rows = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [[String: Any]] else { return (errSecItemNotFound, nil) }
        let matches = rows.filter {
            $0[kSecAttrService as String] as? String == query[kSecAttrService as String] as? String &&
            $0[kSecAttrAccount as String] as? String == query[kSecAttrAccount as String] as? String
        }
        return matches.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, matches)
    }
    func add(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        adds += 1
        guard mayAdd, !FileManager.default.fileExists(atPath: file.path) else { return (errSecDuplicateItem, nil) }
        let reference = Data(UUID().uuidString.utf8)
        var row = attributes; row[kSecValuePersistentRef as String] = reference
        do {
            let bytes = try PropertyListSerialization.data(fromPropertyList: [row], format: .binary, options: 0)
            try bytes.write(to: file, options: .withoutOverwriting)
            guard chmod(file.path, 0o600) == 0 else { return (errSecNotAvailable, nil) }
            return (errSecSuccess, reference)
        } catch { return (errSecNotAvailable, nil) }
    }
}
func activeStableSigningRoot() -> String? { nil }
func activeSyntheticDataGuard() -> SyntheticDataGuard? { nil }
func activeDefaultSessionFile() -> URL { fatalError("The confined process must supply its session default") }

@main struct AuthenticationRegistrationProcessTests {
    static func main() {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        let mode = CommandLine.arguments[1]
        let home = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard home.path.hasPrefix(temporary.path + "/"), home.lastPathComponent.hasPrefix("orbit-registered-process-") else { exit(64) }
        let root = home.appendingPathComponent("root")
        let storage = ProcessRegistrationStorage(file: home.appendingPathComponent("fake-storage"), mayAdd: mode == "prepare")
        do {
            let prepared = try OrbitProductLaunch.prepare(arguments: ["Orbit", "--use-mock-keychain", "--orbit-data-root=" + root.path],
                infoDictionary: [:], applicationSupport: home.appendingPathComponent("invented-home/Library/Application Support"),
                build: OrbitBuildIdentity(bundleIdentifier: nil, signature: nil))
            let lease = prepared.1.recoveryLease!
            let profile = "Chromium/profile-11111111-1111-1111-1111-111111111111"
            if mode == "prepare" {
                let registration = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily)
                let provider = try registration.syntheticKeyProvider(product: .daily, backend: storage)
                _ = try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: provider, profilePath: profile, deadline: 2000)
                try Data("changed".utf8).write(to: root.appendingPathComponent(profile + "/Cookies"))
                guard storage.adds == 1 else { exit(71) }
                print("prepared-registered-evidence")
            } else if mode == "recover" {
                try OrbitAuthenticationStartup.run(configuration: prepared.0, lock: prepared.1, backend: { storage }, now: 1000) {
                    guard storage.reads > 0, storage.adds == 0 else { exit(71) }
                    // This closure replaces all runtime/hooks; no application module is linked.
                    print("admitted-load-only-runtime-not-linked")
                }
            } else { exit(64) }
        } catch {
            guard storage.adds == 0 else { exit(71) }
            print("refused-runtime-not-linked"); exit(65)
        }
    }
}
