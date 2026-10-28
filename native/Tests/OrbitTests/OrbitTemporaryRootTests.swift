import BrowserCore
import Foundation
import Testing
@testable import Orbit

@Suite("Product startup on macOS temporary roots")
struct OrbitTemporaryRootTests {
    @Test func normalizedTemporaryRootPassesRecoveryAndSessionStorage() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-product-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try OrbitProductLaunch.prepare(arguments: ["Orbit", "--use-mock-keychain",
            "--orbit-data-root=" + root.standardizedFileURL.path], infoDictionary: [:],
            applicationSupport: root.appendingPathComponent("home/Library/Application Support"),
            build: OrbitBuildIdentity(bundleIdentifier: nil, signature: nil))
        let configuration = prepared.0
        #expect(configuration.dataRoot.path == root.path)
        let lease = try #require(prepared.1.recoveryLease)
        var started = false
        try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: .daily,
            backend: { throw OrbitRecoveryFailure.keyUnavailable }, runtimeStart: { started = true })
        #expect(started)
        let document = await BrowserStore().sessionDocument()
        try BrowserSessionFileStore().save(document, to: configuration.sessionFile)
        #expect(try BrowserSessionFileStore().load(from: configuration.sessionFile) == document)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(throws: (any Error).self) {
            _ = try OrbitProductLaunch.prepare(arguments: ["Orbit", "--use-mock-keychain",
                "--orbit-data-root=" + alias.appendingPathComponent("other").path], infoDictionary: [:],
                applicationSupport: root.appendingPathComponent("home/Library/Application Support"),
                build: OrbitBuildIdentity(bundleIdentifier: nil, signature: nil))
        }
    }
}
