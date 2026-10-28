import Foundation
import Testing
@testable import Orbit

@Suite("Chromium Live configuration")
struct OrbitLiveConfigurationTests {
    private let support = URL(fileURLWithPath: "/Users/synthetic/Library/Application Support", isDirectory: true)
    private var live: OrbitBuildIdentity {
        OrbitBuildIdentity(bundleIdentifier: "io.github.okatech.orbit.test.orbit.live", signature: OrbitCodeSignature(
            identifier: "io.github.okatech.orbit.test.orbit.live", isAdHoc: false, isValid: true,
            anchorCommonName: "Orbit Lab Local Development", satisfiesStableRequirement: true))
    }
    private let info: [String: Any] = ["CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.live"]

    @Test("Live starts without arguments with separate persistent storage and real secure storage")
    func defaults() throws {
        let configuration = try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: info,
                                                         applicationSupport: support, build: live)
        #expect(configuration.dataRoot.path == support.path + "/Orbit Live Chromium")
        #expect(configuration.sessionFile.path == support.path + "/Orbit Live Chromium/session.json")
        #expect(configuration.engineRoot.path == support.path + "/Orbit Live Chromium/Chromium")
        #expect(configuration.secureStorage == .keychain(service: "Orbit Live Safe Storage", account: "Orbit Live"))
        #expect(configuration.usesProductNetwork)
    }

    @Test("Live refuses synthetic product metadata, untrusted signatures and data or session redirection")
    func refusals() {
        for arguments in [["Orbit", "--orbit-data-root=" + support.path + "/Orbit"],
                          ["Orbit", "--session-file", support.path + "/Orbit/session.json"],
                          ["Orbit", "--session-file=" + support.path + "/Orbit Live/session.json"]] {
            #expect(throws: OrbitProductConfiguration.Failure.self) {
                try OrbitProductConfiguration(arguments: arguments, infoDictionary: info,
                                             applicationSupport: support, build: live)
            }
        }
        for key in ["OrbitDataRoot", "OrbitUseMockKeychain", "OrbitSyntheticBundle"] {
            var metadata = info
            metadata[key] = key == "OrbitDataRoot" ? "/private/tmp/orbit-live/data" : true
            #expect(throws: OrbitProductConfiguration.Failure.productBundleHasSyntheticSettings) {
                try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: metadata,
                                             applicationSupport: support, build: live)
            }
        }
        var wrongCertificate = live
        wrongCertificate.signature?.satisfiesStableRequirement = false
        #expect(wrongCertificate.productRefusal != nil)
        var unsigned = live
        unsigned.signature?.isAdHoc = true
        #expect(unsigned.productRefusal != nil)
        var mismatched = live
        mismatched.signature?.identifier = "io.github.okatech.orbit"
        #expect(mismatched.productRefusal != nil)
        var invalid = live
        invalid.signature?.isValid = false
        #expect(invalid.productRefusal != nil)
    }

    @Test("A synthetic Live test identity stays confined with mock secure storage even without arguments")
    func bakedSynthetic() throws {
        let configuration = try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: [
            "CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.live.test", "OrbitDataRoot": "/private/tmp/orbit-live-synthetic/data",
            "OrbitUseMockKeychain": true, "OrbitSyntheticBundle": true
        ], applicationSupport: support, build: OrbitBuildIdentity(bundleIdentifier: "io.github.okatech.orbit.test.orbit.live.test", signature: nil))
        #expect(configuration.usesMockKeychain)
        #expect(!configuration.usesProductNetwork)
        #expect(configuration.syntheticGuard != nil)
        for name in ["Orbit", "Orbit Live", "Orbit Live Chromium"] {
            #expect(throws: OrbitProductConfiguration.Failure.mockKeychainOnPersonalRoot) {
                try OrbitProductConfiguration(arguments: ["Orbit", "--use-mock-keychain",
                    "--orbit-data-root=" + support.path + "/" + name], applicationSupport: support, build: live)
            }
        }
    }
}
