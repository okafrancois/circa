import AppKit
import BrowserCore
import CoreServices
import Security
import UniformTypeIdentifiers

struct BrowserDefaultBrowserStatus: Equatable {
    let http: String
    let https: String
    let html: String
    var isOrbit: Bool { http == ProductIdentity.bundleIdentifier && https == ProductIdentity.bundleIdentifier && html == ProductIdentity.bundleIdentifier }
}

enum BrowserDefaultBrowserError: Error { case unavailableProduct, invalidSignature }

/// Uses the same public NSWorkspace APIs and ordering as orbit-default-browser.py. No script,
/// shell, Keychain, system-dialog automation or implicit request is involved.
@MainActor
struct BrowserDefaultBrowserService {
    var status: () -> BrowserDefaultBrowserStatus = {
        func handler(_ scheme: String) -> String {
            LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String? ?? ""
        }
        return BrowserDefaultBrowserStatus(http: handler("http"), https: handler("https"),
            html: LSCopyDefaultRoleHandlerForContentType(UTType.html.identifier as CFString, .viewer)?.takeRetainedValue() as String? ?? "")
    }
    var canRequest: () -> Bool = { Bundle.main.bundleIdentifier == ProductIdentity.bundleIdentifier }
    var request: () async throws -> Void = {
        guard Bundle.main.bundleIdentifier == ProductIdentity.bundleIdentifier else { throw BrowserDefaultBrowserError.unavailableProduct }
        let url = Bundle.main.bundleURL
        try BrowserDefaultBrowserService.validateSignature(at: url)
        // These calls may display macOS confirmation dialogs. They are left to the user.
        try await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "http")
        try await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "https")
        try await NSWorkspace.shared.setDefaultApplication(at: url, toOpen: UTType.html)
    }

    /// The bundle must carry the product identifier and satisfy its own designated requirement,
    /// whichever identity signed it (release Developer ID or a local build). Only signature
    /// metadata is read; no file outside the bundle and no Keychain item is involved.
    nonisolated static func validateSignature(at url: URL, identifier: String = ProductIdentity.bundleIdentifier) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String == identifier,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
        else { throw BrowserDefaultBrowserError.invalidSignature }
    }
}
