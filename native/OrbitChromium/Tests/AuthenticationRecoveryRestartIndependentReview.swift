import BrowserCore
import CryptoKit
import Darwin
import Foundation

private struct IndependentProcessKey: OrbitRecoveryKeyProvider {
    let file: URL
    func loadRecoveryKey(transaction: UUID) throws -> SymmetricKey {
        let bytes = try Data(contentsOf: file)
        guard bytes.count == 32 else { throw OrbitRecoveryFailure.keyUnavailable }
        return SymmetricKey(data: bytes)
    }
}

// Offline recovery only: link BrowserCore, never an engine/application module. Missing arguments
// or an unexpected root always refuse; the launcher cannot fall back to a personal data root.
@main struct AuthenticationRecoveryRestartIndependentReview {
    static func main() {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        let operation = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        let home = root.deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        guard root.path.hasPrefix(temporary), root.lastPathComponent == "root",
              home.lastPathComponent.hasPrefix("orbit-process-recovery-review-") else { exit(64) }
        do {
            let lease = try OrbitRecoveryRootLock(root: root)
            let key = IndependentProcessKey(file: home.appendingPathComponent("independent-key"))
            if operation == "prepare" {
                let transaction = try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: key,
                    profilePath: "Chromium/profile-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    deadline: Int64(Date().timeIntervalSince1970) + 600)
                do {
                    try transaction.withSyntheticMutation {
                        try Data("changed-cookie-fixture".utf8).write(to: root.appendingPathComponent("Chromium/profile-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/Cookies"))
                        try Data("changed-session-fixture".utf8).write(to: root.appendingPathComponent("session.json"))
                        throw OrbitRecoveryFailure.injected
                    }
                    exit(71)
                } catch OrbitRecoveryFailure.injected { print("prepared-applying"); return }
            }
            guard operation == "recover" || operation == "interrupt" else { exit(64) }
            var writes = 0
            try OrbitAuthenticationStartupGate.run(lease: lease, provider: key, failpoint: { boundary in
                if operation == "interrupt", boundary == .restoreChunk {
                    writes += 1
                    if writes == 2 { throw OrbitRecoveryFailure.injected }
                }
            }) { print("recovery-complete-runtime-not-linked") }
        } catch OrbitRecoveryFailure.injected { print("restore-interrupted-runtime-not-linked"); exit(70) }
        catch { print("recovery-refused-runtime-not-linked"); exit(65) }
    }
}
