import BrowserCore
import CryptoKit
import Darwin
import Foundation

/// Fault injection is confined to the explicitly signed synthetic bundle and its baked root.
/// The product never reads these environment settings or writes probe evidence.
enum ChromiumImportRecoveryProbe {
    static func checkpoint(_ point: String, configuration: OrbitProductConfiguration) throws {
        guard configuration.usesMockKeychain, let confinement = configuration.syntheticGuard,
              Bundle.main.bundleIdentifier == "lab.orbit.orbit.import-recovery",
              ProcessInfo.processInfo.environment["ORBIT_IMPORT_RECOVERY_PROBE"] == "1" else { return }
        try confinement.checkRoot()
        let root = configuration.dataRoot
        var inventory: [String: String] = [:]
        if point == "recovered" {
            for case let file as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                if relative.hasPrefix("ImportRecovery") || relative.hasPrefix("Import/Backups") || relative.hasPrefix("AuthenticationImport") || relative.hasPrefix(".orbit") || relative == "import-recovery-startup.json" { continue }
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    inventory[relative] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        let result: [String: Any] = ["point": point, "pid": getpid(), "inventory": inventory]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: root.appendingPathComponent("import-recovery-startup.json"), options: .atomic)
        if ProcessInfo.processInfo.environment["ORBIT_IMPORT_RECOVERY_KILL"] == point {
            kill(getpid(), SIGKILL)
            while true { pause() }
        }
    }
}
