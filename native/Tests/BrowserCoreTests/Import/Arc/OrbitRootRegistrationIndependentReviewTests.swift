import Darwin
import Foundation
import Security
import Testing
@testable import BrowserCore

private final class ReviewRegistrationStorage: OrbitRecoverySecItemBoundary {
    var calls = 0
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        calls += 1
        return (errSecItemNotFound, nil)
    }
    func add(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        calls += 1
        return (errSecNotAvailable, nil)
    }
}

private final class ReviewRegistrationRoot {
    let url: URL
    let storage = ReviewRegistrationStorage()
    init() throws {
        url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("orbit-registration-independent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let marker = url.appendingPathComponent(OrbitAuthenticationRecovery.syntheticMarker)
        try Data("orbit-auth-recovery-synthetic-v1\n".utf8).write(to: marker)
        guard chmod(marker.path, 0o600) == 0 else { throw OrbitRecoveryFailure.io }
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("Independent exact-source root registration review", .serialized)
struct OrbitRootRegistrationIndependentReviewTests {
    // Intentionally red on 1216ed26: this is the same shared lock required by
    // BrowserEnvironment.open before it can load any persistent session.
    @Test(arguments: [false, true])
    func runtimeMustPermitItsOwnPersistentSessionReadLock(_ registered: Bool) throws {
        let fixture = try ReviewRegistrationRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        if registered { _ = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily) }
        // Retained pre-registration startup demonstrates the compatible baseline.
        try OrbitAuthenticationStartupGate.run(lease: lease) {
            let reader = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: false, validatingPath: false)
            reader.release()
        }
        var failure: ArcImportError?
        try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: .daily, backend: { fixture.storage }) {
            do {
                let reader = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: false, validatingPath: false)
                reader.release()
            } catch let error as ArcImportError { failure = error }
        }
        #expect(failure == nil)
        #expect(fixture.storage.calls == 0)
        // Exclusion belongs to the startup lifetime, not to a prior abandoned fixture.
        let reader = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: false, validatingPath: false)
        reader.release()
    }

    @Test(arguments: [false, true])
    func explicitExtendedACLRefusesWithoutStorage(_ rootACL: Bool) throws {
        let fixture = try ReviewRegistrationRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        _ = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily)
        let target = rootACL ? fixture.url : fixture.url.appendingPathComponent(OrbitRecoveryRootRegistration.fileName)
        let chmodACL = Process()
        chmodACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodACL.arguments = ["+a", "everyone allow read", target.path]
        try chmodACL.run(); chmodACL.waitUntilExit()
        #expect(chmodACL.terminationStatus == 0)
        var started = false
        #expect(throws: (any Error).self) {
            try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: .daily, backend: { fixture.storage }) { started = true }
        }
        #expect(!started && fixture.storage.calls == 0)
    }

    @Test func inPlaceUnknownRegistrationFieldIsNotIgnored() throws {
        let fixture = try ReviewRegistrationRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        _ = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily)
        let target = fixture.url.appendingPathComponent(OrbitRecoveryRootRegistration.fileName)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
        object["unrecognizedAuthority"] = true
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: target)
        #expect(throws: (any Error).self) {
            try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: .daily, backend: { fixture.storage }) {}
        }
        #expect(fixture.storage.calls == 0)
    }

    @Test func modeChangeDuringPublicationRetainsInterruptedEvidence() throws {
        let fixture = try ReviewRegistrationRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        #expect(throws: (any Error).self) {
            try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily) { boundary in
                if boundary == .durable { #expect(chmod(fixture.url.path, 0o750) == 0) }
            }
        }
        #expect(chmod(fixture.url.path, 0o700) == 0)
        #expect(try lease.root.info(OrbitRecoveryRootRegistration.fileName) == nil)
        #expect(try lease.root.info(OrbitRecoveryRootRegistration.fileName + ".writing") != nil)
        #expect(throws: (any Error).self) {
            try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: .daily, backend: { fixture.storage }) {}
        }
        #expect(fixture.storage.calls == 0)
    }
}
