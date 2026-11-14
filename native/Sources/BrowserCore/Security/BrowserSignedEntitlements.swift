import Foundation
import Security

public enum BrowserSignedEntitlements {
    /// Entitlements of this process's verified signature, never a plist assertion or a build flag.
    /// Returns nil when the running code is unsigned or fails validity checks.
    public static func current() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    }
}
