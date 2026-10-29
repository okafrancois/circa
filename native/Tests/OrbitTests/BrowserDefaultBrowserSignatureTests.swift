import Foundation
import Testing
@testable import Orbit

@Suite("Default browser signature check")
struct BrowserDefaultBrowserSignatureTests {
    private let signedApp = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    @Test("A validly signed bundle passes against its own designated requirement without any local file")
    func ownRequirement() throws {
        try BrowserDefaultBrowserService.validateSignature(at: signedApp, identifier: "com.apple.calculator")
    }

    @Test("A signed bundle with another identifier, or a missing bundle, is refused")
    func refusals() {
        #expect(throws: BrowserDefaultBrowserError.self) {
            try BrowserDefaultBrowserService.validateSignature(at: signedApp, identifier: "io.github.okatech.orbit")
        }
        #expect(throws: BrowserDefaultBrowserError.self) {
            try BrowserDefaultBrowserService.validateSignature(at: URL(fileURLWithPath: "/nonexistent/Orbit.app"))
        }
    }
}
