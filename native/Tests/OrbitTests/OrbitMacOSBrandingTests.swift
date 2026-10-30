import Foundation
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Orbit macOS branding preserves storage identity")
@MainActor
struct OrbitMacOSBrandingTests {
    @Test("Display metadata cannot change product admission, data roots or secure storage")
    func productIdentities() throws {
        let support = URL(fileURLWithPath: "/Users/synthetic/Library/Application Support")
        for (identifier, technicalName, displayedName, root) in [
            ("io.github.okatech.orbit", "Orbit", "Circa", "Orbit"),
            ("io.github.okatech.orbit.test.orbit.live", "Orbit Live", "Circa", "Orbit Live Chromium")
        ] {
            let identity = OrbitBuildIdentity(bundleIdentifier: identifier, signature: OrbitCodeSignature(
                identifier: identifier, isAdHoc: false, isValid: true,
                anchorCommonName: "Orbit Lab Local Development", satisfiesStableRequirement: true))
            let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": displayedName,
                                     "CFBundleDisplayName": "Orbit", "CFBundleIconFile": "Orbit.icns"]
            let configuration = try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: info,
                                                             applicationSupport: support, build: identity)
            #expect(configuration.secureStorage == .keychain(service: technicalName + " Safe Storage", account: technicalName))
            #expect(configuration.dataRoot == support.appendingPathComponent(root, isDirectory: true))
            #expect(configuration.sessionFile == configuration.dataRoot.appendingPathComponent("session.json"))
            #expect(configuration.usesProductNetwork && !configuration.usesMockKeychain)
            #expect(BrowserCommandMenus<NSObject>.applicationDisplayName(bundleIdentifier: identifier) == displayedName)
            #expect(OrbitCodeSignature.stableRequirement(rootSHA1: String(repeating: "AB", count: 20), identifier: identifier)
                    == "identifier \"\(identifier)\" and certificate root = H\"\(String(repeating: "AB", count: 20))\"")
        }
    }

    @Test("Synthetic identity remains refused in product mode regardless of displayed name")
    func syntheticAdmission() {
        let identity = OrbitBuildIdentity(bundleIdentifier: "io.github.okatech.orbit.test.orbit.orbit-test", signature: nil)
        #expect(identity.productRefusal != nil)
        #expect(BrowserCommandMenus<NSObject>.applicationDisplayName(bundleIdentifier: identity.bundleIdentifier) == "Circa")
    }
}
}
