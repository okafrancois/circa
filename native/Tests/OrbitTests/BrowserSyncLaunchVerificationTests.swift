import Testing
@testable import Orbit

@MainActor
struct BrowserSyncLaunchVerificationTests {
    @Test("Ordinary launches never run verification")
    func ordinaryLaunch() {
        #expect(BrowserSyncLaunchVerification.run(arguments: ["Orbit"], availability: {
            Issue.record("Unexpected signature inspection")
            return false
        }) == nil)
    }

    @Test("Verification reports runtime admission and exits without starting the app")
    func admission() {
        for available in [true, false] {
            var output = ""
            let result = BrowserSyncLaunchVerification.run(arguments: ["Orbit", "--orbit-verify-icloud"],
                availability: { available }, report: { output = $0 })
            #expect(result == (available ? 0 : 69))
            #expect(output == "{\"icloudAvailable\":\(available),\"storageInitialized\":false}")
        }
    }

    @Test("Mixed launch options fail before signature inspection or storage")
    func mixedOptions() {
        #expect(BrowserSyncLaunchVerification.run(arguments: ["Orbit", "--orbit-verify-icloud", "--ephemeral"],
            availability: { Issue.record("Unexpected signature inspection"); return true }) == 64)
    }
}
