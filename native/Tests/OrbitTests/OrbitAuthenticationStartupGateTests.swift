import BrowserCore
import Foundation
import Testing
@testable import Orbit

@Suite("Product preparation precedes the authentication runtime seam")
struct OrbitAuthenticationStartupGateTests {
    @Test func preparedRootAllowsOrdinaryStartButIncompleteIntentHaltsAllHooks() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("orbit-product-gate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("root")
        let prepared = try OrbitProductLaunch.prepare(arguments: ["Orbit", "--use-mock-keychain", "--orbit-data-root=" + root.path], infoDictionary: [:], applicationSupport: home.appendingPathComponent("home/Library/Application Support"), build: OrbitBuildIdentity(bundleIdentifier: nil, signature: nil))
        let lease = try #require(prepared.1.recoveryLease)
        var runtimeStarts = 0
        try OrbitAuthenticationStartupGate.run(lease: lease) { runtimeStarts += 1 }
        #expect(runtimeStarts == 1)
        let marker = root.appendingPathComponent(".orbit-auth-recovery-required")
        try Data("incomplete-invented-intent".utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        #expect(throws: (any Error).self) {
            try OrbitAuthenticationStartupGate.run(lease: lease) { runtimeStarts += 1 }
        }
        #expect(runtimeStarts == 1)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
