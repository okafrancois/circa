import Testing
@testable import Orbit

struct BrowserExtensionRetryTests {
    @Test("Persistent registry failure has bounded hourly retries without losing eventual readiness")
    func hourlyBudget() {
        var elapsed = 0.0
        var retries = 0
        while elapsed < 3600 {
            elapsed += BrowserExtensionRetryPolicy.delay(attempt: retries)
            if elapsed <= 3600 { retries += 1 }
        }
        #expect(retries <= 70)
        #expect(BrowserExtensionRetryPolicy.delay(attempt: 0) == 0.05)
        #expect(BrowserExtensionRetryPolicy.delay(attempt: 10000) == 60)
        print("extension retry upper bound per hour=\(retries)")
    }
}
