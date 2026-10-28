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
        // Match the persisted public certificate fingerprint used by orbit-app.py. This reads
        // metadata only; the signing keychain and its password are never opened.
        let identityURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/orbit/signing/identity.json")
        struct Identity: Decodable { let fingerprint: String }
        let identity = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: identityURL))
        guard identity.fingerprint.count == 40,
              identity.fingerprint.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789ABCDEFabcdef").contains($0) }) else {
            throw BrowserDefaultBrowserError.invalidSignature
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("identifier \"\(ProductIdentity.bundleIdentifier)\" and certificate root = H\"\(identity.fingerprint)\"" as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw BrowserDefaultBrowserError.invalidSignature }
        // These calls may display macOS confirmation dialogs. They are left to the user.
        try await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "http")
        try await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "https")
        try await NSWorkspace.shared.setDefaultApplication(at: url, toOpen: UTType.html)
    }
}
