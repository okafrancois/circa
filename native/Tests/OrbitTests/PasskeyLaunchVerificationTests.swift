import BrowserCore
import Testing
@testable import Orbit

@MainActor
struct PasskeyLaunchVerificationTests {
    @Test("Ordinary launches never inspect the signature")
    func ordinaryLaunch() {
        #expect(PasskeyLaunchVerification.run(arguments: ["Orbit"], entitlements: {
            Issue.record("Unexpected signature inspection")
            return nil
        }) == nil)
    }

    @Test("A signed browser entitlement reports the provider authorization and exits")
    func signedEntitlement() {
        var output = ""
        let result = PasskeyLaunchVerification.run(arguments: ["Orbit", "--orbit-verify-passkeys"],
            entitlements: { [PasskeySystemSupport.browserEntitlement: true] },
            authorization: { "notDetermined" }, report: { output = $0 })
        #expect(result == 0)
        #expect(output == "{\"browserPasskeys\":true,\"authorization\":\"notDetermined\"}")
    }

    @Test("Without the entitlement the provider is never queried")
    func missingEntitlement() {
        for entitlements in [nil, [:], [PasskeySystemSupport.browserEntitlement: false],
                             [PasskeySystemSupport.browserEntitlement: "true"]] as [[String: Any]?] {
            var output = ""
            let result = PasskeyLaunchVerification.run(arguments: ["Orbit", "--orbit-verify-passkeys"],
                entitlements: { entitlements },
                authorization: { Issue.record("Unexpected provider query"); return "authorized" },
                report: { output = $0 })
            #expect(result == 69)
            #expect(output == "{\"browserPasskeys\":false,\"authorization\":\"unavailable\"}")
        }
    }

    @Test("Mixed launch options fail before signature inspection")
    func mixedOptions() {
        #expect(PasskeyLaunchVerification.run(arguments: ["Orbit", "--orbit-verify-passkeys", "--ephemeral"],
            entitlements: { Issue.record("Unexpected signature inspection"); return nil }) == 64)
    }

    @Test("An unsigned test process has no browser passkey entitlement")
    func unsignedProcess() {
        #expect(!PasskeySystemSupport.browserPasskeysSigned(BrowserSignedEntitlements.current()))
    }
}

