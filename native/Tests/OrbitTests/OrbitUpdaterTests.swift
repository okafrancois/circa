import Foundation
import Testing
@testable import Orbit

@Suite("Updater admission without network")
struct OrbitUpdaterTests {
    private var production: [String: Any] { [
        "SUPublicEDKey": Data(repeating: 42, count: 32).base64EncodedString(),
        "SUFeedURL": "https://github.com/okafrancois/orbit-browser/releases/latest/download/appcast.xml"
    ] }

    @Test("Missing keys and ordinary synthetic bundles never start an updater")
    func disabledTests() {
        #expect(OrbitUpdatePolicy.permits(info: production, synthetic: false, arguments: []) == true)
        #expect(OrbitUpdatePolicy.permits(info: production, synthetic: true, arguments: []) == false)
        var info = production
        for key in ["", "invalid", Data(repeating: 1, count: 31).base64EncodedString()] {
            info["SUPublicEDKey"] = key
            #expect(!OrbitUpdatePolicy.permits(info: info, synthetic: false, arguments: []))
        }
        #expect(!OrbitUpdatePolicy.permits(info: production, synthetic: false, arguments: ["--use-mock-keychain"]))
        #expect(!OrbitUpdatePolicy.permits(info: production, synthetic: false, arguments: ["--ephemeral"]))
    }

    @Test("Only an explicitly isolated updater E2E can use the loopback feed")
    func loopbackException() {
        var info = production
        info.merge(["CFBundleIdentifier": "io.github.okatech.orbit.test.update", "OrbitSyntheticBundle": true,
                    "OrbitUseMockKeychain": true, "OrbitUpdaterLocalTest": true,
                    "SUFeedURL": "http://127.0.0.1:12345/appcast.xml"]) { _, new in new }
        #expect(OrbitUpdatePolicy.permits(info: info, synthetic: true, arguments: []))
        #expect(!OrbitUpdatePolicy.permits(info: info, synthetic: false, arguments: []))
        info["SUFeedURL"] = "https://github.com/appcast.xml"
        #expect(!OrbitUpdatePolicy.permits(info: info, synthetic: true, arguments: []))
        info["SUFeedURL"] = "http://localhost:12345/appcast.xml"
        #expect(!OrbitUpdatePolicy.permits(info: info, synthetic: true, arguments: []))
    }
}
