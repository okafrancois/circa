import BrowserCore
import Foundation
import Security
import Testing
@testable import Orbit

@Suite struct ChromiumImportKeychainTests {
    private final class Boundary: OrbitRecoverySecItemBoundary {
        var queries: [[String: Any]] = []
        var status = errSecSuccess
        func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
            queries.append(query); return (status, Data("mock_password".utf8))
        }
        func add(_ attributes: [String: Any]) -> (OSStatus, Any?) { Issue.record("Source item must never be created"); return (errSecAuthFailed, nil) }
    }
    @Test func explicitSelectionOnly() throws {
        let boundary = Boundary(), reader = ChromiumImportKeychain(boundary: Boundary())
        #expect(throws: BrowserAuthenticationImportError.consentRequired) { try reader.readSource(sourceID: "chrome", userConsented: false) }
        let selected = ChromiumImportKeychain(boundary: boundary)
        #expect(boundary.queries.isEmpty)
        _ = try selected.readSource(sourceID: "brave", userConsented: true)
        #expect(boundary.queries.count == 1)
        #expect(boundary.queries[0][kSecAttrService as String] as? String == "Brave Safe Storage")
        #expect(boundary.queries[0][kSecAttrAccount as String] as? String == "Brave")
        boundary.status = errSecAuthFailed
        #expect(throws: BrowserAuthenticationImportError.keychainDenied) { try selected.readSource(sourceID: "chrome", userConsented: true) }
        #expect(boundary.queries.count == 2)
        #expect(throws: BrowserAuthenticationImportError.unsupportedSource) { try selected.readSource(sourceID: "unknown", userConsented: true) }
        #expect(boundary.queries.count == 2)
    }
}
