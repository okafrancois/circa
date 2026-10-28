import Darwin
import Foundation
import Security
import Testing
@testable import Orbit

// CHROMIUM-APP-R2 (packaging review): product mode only for the packaged, stably signed
// `io.github.okatech.orbit.test.orbit` bundle, refused before anything is created; one running Orbit per data root.
// Synthetic directories only; the personal data root of the fake home is never created.

extension OrbitBuildIdentity {
    /// The packaged product signed with the stable local identity.
    static let stableProductForTests = OrbitBuildIdentity(
        bundleIdentifier: "io.github.okatech.orbit",
        signature: OrbitCodeSignature(identifier: "io.github.okatech.orbit", isAdHoc: false, isValid: true,
                                     anchorCommonName: "Orbit Lab Local Development", satisfiesStableRequirement: true))
}

@Suite("Chromium product admission", .serialized)
struct OrbitBuildIdentityTests {
    private let support = URL(fileURLWithPath: "/Users/synthetic/Library/Application Support", isDirectory: true)

    private func refusal(_ build: OrbitBuildIdentity, arguments: [String] = ["Orbit"]) -> String? {
        do {
            _ = try OrbitProductConfiguration(arguments: arguments, applicationSupport: support, build: build)
            return nil
        } catch OrbitProductConfiguration.Failure.productBuildRefused(let reason) {
            return reason
        } catch {
            Issue.record("Unexpected error \(error)")
            return nil
        }
    }

    @Test("Only the two explicit channel bundles may run as products")
    func bundleIdentifierIsExact() {
        let stable = OrbitBuildIdentity.stableProductForTests
        #expect(refusal(stable) == nil)
        for identifier: String? in [nil, "io.github.okatech.orbit.test.orbit.unpackaged", "io.github.okatech.orbit.test.orbit-chromium.app-smoke", "LAB.INVALID.ORBIT",
                                    "io.github.okatech.orbit.test.orbit.dev", "io.github.okatech.orbit.test.orbit-chromium.synthetic"] {
            var build = stable
            build.bundleIdentifier = identifier
            #expect(refusal(build)?.contains("bundle identifier") == true, "identifier \(identifier ?? "none")")
        }
        // A bare executable (product-bin/Orbit, smoke-bin/Orbit) has no bundle identifier.
        #expect(refusal(OrbitBuildIdentity(bundleIdentifier: nil, signature: stable.signature)) != nil)
    }

    @Test("A valid Apple Developer ID Application signature admits the configured product")
    func developerIDProduct() {
        var product = OrbitBuildIdentity.stableProductForTests
        product.signature?.satisfiesStableRequirement = false
        product.signature?.anchorCommonName = "Apple Root CA"
        product.signature?.satisfiesDeveloperIDRequirement = true
        #expect(refusal(product) == nil)
        product.signature?.isValid = false
        #expect(refusal(product) == "invalid code signature")
        product.signature?.isValid = true
        product.signature?.identifier = "other.application"
        #expect(refusal(product)?.contains("signing identifier") == true)
    }

    @Test("The product needs a valid signature anchored on the stable identity, never ad hoc")
    func signatureIsStable() {
        let stable = OrbitBuildIdentity.stableProductForTests
        var missing = stable
        missing.signature = nil
        #expect(refusal(missing) == "no readable code signature")
        var adHoc = stable
        adHoc.signature?.isAdHoc = true
        adHoc.signature?.anchorCommonName = nil
        #expect(refusal(adHoc) == "ad hoc code signature")
        var invalid = stable
        invalid.signature?.isValid = false
        #expect(refusal(invalid) == "invalid code signature")
        var identifier = stable
        identifier.signature?.identifier = "io.github.okatech.orbit.test.orbit.unpackaged"
        #expect(refusal(identifier)?.contains("signing identifier") == true)
        var otherCertificate = stable
        otherCertificate.signature?.anchorCommonName = "Apple Root CA"
        #expect(refusal(otherCertificate) == "signature is not anchored on the stable local identity")
    }

    @Test("R3: the stable identity is an explicit requirement on its certificate, not its name")
    func explicitRequirement() throws {
        #expect(OrbitCodeSignature.stableRequirement(rootSHA1: nil) == nil)
        #expect(OrbitCodeSignature.stableRequirement(rootSHA1: "not-a-fingerprint") == nil)
        let fingerprint = String(repeating: "A1", count: 20)
        #expect(OrbitCodeSignature.stableRequirement(rootSHA1: fingerprint.lowercased())
                == "identifier \"io.github.okatech.orbit\" and certificate root = H\"\(fingerprint)\"")
        #expect(OrbitCodeSignature.stableRequirement(rootSHA1: fingerprint, identifier: "io.github.okatech.orbit.test.orbit.live")
                == "identifier \"io.github.okatech.orbit.test.orbit.live\" and certificate root = H\"\(fingerprint)\"")
        for identifier in ["io.github.okatech.orbit.test.orbit.live.test", "io.github.okatech.orbit.test.other", "LAB.INVALID.ORBIT", "io.github.okatech.orbit.test.orbit.unpackaged"] {
            #expect(OrbitCodeSignature.stableRequirement(rootSHA1: fingerprint, identifier: identifier) == nil)
        }
        // Same name, another certificate: the requirement decides.
        var sameName = OrbitBuildIdentity.stableProductForTests
        sameName.signature?.satisfiesStableRequirement = false
        #expect(refusal(sameName) == "signature does not satisfy the stable local identity requirement")
        // Real Security framework: this test process satisfies its own designated requirement, never
        // a foreign certificate root, and a malformed requirement is refused.
        var code: SecCode?
        #expect(SecCodeCopySelf([], &code) == errSecSuccess)
        let selfCode = try #require(code)
        var staticCode: SecStaticCode?
        #expect(SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess)
        var designated: SecRequirement?
        #expect(SecCodeCopyDesignatedRequirement(try #require(staticCode), [], &designated) == errSecSuccess)
        var text: CFString?
        #expect(SecRequirementCopyString(try #require(designated), [], &text) == errSecSuccess)
        #expect(OrbitCodeSignature.satisfies(selfCode, requirement: try #require(text) as String))
        #expect(!OrbitCodeSignature.satisfies(selfCode, requirement: try #require(OrbitCodeSignature.stableRequirement(rootSHA1: fingerprint))))
        #expect(!OrbitCodeSignature.satisfies(selfCode, requirement: "identifier ("))
        #expect(OrbitCodeSignature.current(stableRootSHA1: fingerprint)?.satisfiesStableRequirement == false)
        #expect(OrbitCodeSignature.current(stableRootSHA1: nil)?.satisfiesStableRequirement == false)
    }

    @Test("Only the admitted product uses Chromium's product network services; synthetic runs stay hermetic")
    func networkPolicyPerMode() throws {
        let product = try OrbitProductConfiguration(arguments: ["Orbit"], applicationSupport: support, build: .stableProductForTests)
        #expect(product.usesProductNetwork)
        let synthetic = try OrbitProductConfiguration(arguments: ["Orbit", "--use-mock-keychain", "--orbit-data-root=/private/tmp/orbit-net/data"],
                                                     applicationSupport: support, build: .stableProductForTests)
        #expect(!synthetic.usesProductNetwork)
        let baked = try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: [
            "CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.net-test", "OrbitDataRoot": "/private/tmp/orbit-net/plist",
            "OrbitUseMockKeychain": true], applicationSupport: support, build: OrbitBuildIdentity(bundleIdentifier: nil, signature: nil))
        #expect(!baked.usesProductNetwork)
    }

    @Test("Synthetic runs do not depend on the bundle; the test process itself is not the product")
    func syntheticRunsAndRealReader() throws {
        let bare = OrbitBuildIdentity(bundleIdentifier: nil, signature: nil)
        let synthetic = try OrbitProductConfiguration(arguments: ["Orbit", "--use-mock-keychain", "--orbit-data-root=/private/tmp/orbit-id/data"],
                                                     applicationSupport: support, build: bare)
        #expect(synthetic.usesMockKeychain)
        let plist = try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: ["CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.id-test",
                                                                                      "OrbitDataRoot": "/private/tmp/orbit-id/plist",
                                                                                      "OrbitUseMockKeychain": true],
                                                 applicationSupport: support, build: bare)
        #expect(plist.usesMockKeychain)
        let current = OrbitBuildIdentity.current()
        #expect(current.signature != nil)
        #expect(current.productRefusal != nil)
    }

    @Test("A refused product creates nothing; a data root has one running instance in every spelling")
    func launchPreparationAndLock() throws {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("orbit-launch-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        defer { try? manager.removeItem(at: base) }
        let home = base.appendingPathComponent("home/Library/Application Support", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        let personal = home.appendingPathComponent("Orbit", isDirectory: true)

        #expect(throws: OrbitProductConfiguration.Failure.self) {
            _ = try OrbitProductLaunch.prepare(arguments: ["Orbit"], infoDictionary: [:], applicationSupport: home,
                                              build: OrbitBuildIdentity(bundleIdentifier: nil, signature: nil))
        }
        #expect(!manager.fileExists(atPath: personal.path))

        let root = base.appendingPathComponent("run/data", isDirectory: true)
        let arguments = ["Orbit", "--use-mock-keychain", "--orbit-data-root=" + root.path]
        let bare = OrbitBuildIdentity(bundleIdentifier: nil, signature: nil)
        var first: (OrbitProductConfiguration, OrbitDataRootLock)? = try OrbitProductLaunch.prepare(
            arguments: arguments, infoDictionary: [:], applicationSupport: home, build: bare)
        let physical = try #require(realpath(root.path, nil))
        defer { free(physical) }
        let physicalRoot = String(cString: physical)
        #expect(first?.0.dataRoot.path == physicalRoot)
        #expect(throws: OrbitDataRootLock.Failure.alreadyInUse(physicalRoot + "/.orbit-instance.lock")) {
            _ = try OrbitProductLaunch.prepare(arguments: arguments, infoDictionary: [:], applicationSupport: home, build: bare)
        }
        // Another spelling of the same root shares the lock file.
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        try manager.createSymbolicLink(at: alias, withDestinationURL: base.appendingPathComponent("run", isDirectory: true))
        #expect(throws: OrbitDataRootLock.Failure.self) {
            _ = try OrbitDataRootLock(dataRoot: alias.appendingPathComponent("data", isDirectory: true))
        }
        first?.1.release()
        first = nil
        let second = try OrbitProductLaunch.prepare(arguments: arguments, infoDictionary: [:], applicationSupport: home, build: bare)
        second.1.release()
        // The lock file is a plain file inside the root, accepted by the layout check.
        try second.0.prepareDirectories()
    }
}
