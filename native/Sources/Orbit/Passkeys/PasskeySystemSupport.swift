import AuthenticationServices
import BrowserCore
import Foundation

/// The engine reaches the macOS passkey provider (iCloud Keychain, the Passwords app and
/// Touch ID) only when Apple's managed browser entitlement is part of the signature. The
/// authorization prompt itself is requested by the engine during the first ceremony.
enum PasskeySystemSupport {
    static let browserEntitlement = "com.apple.developer.web-browser.public-key-credential"

    static func browserPasskeysSigned(_ entitlements: [String: Any]?) -> Bool {
        entitlements?[browserEntitlement] as? Bool == true
    }

    /// Read-only: never requests authorization, so it cannot show a system prompt.
    static func authorizationState() -> String {
        switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
        case .authorized: "authorized"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }
}

/// Executed before the launcher, AppKit, CEF, defaults, Keychain or session storage, like the
/// iCloud verification. Launch the executable directly; LaunchServices could route to an
/// existing personal instance.
@MainActor
enum PasskeyLaunchVerification {
    static let argument = "--orbit-verify-passkeys"

    static func run(arguments: [String],
                    entitlements: () -> [String: Any]? = BrowserSignedEntitlements.current,
                    authorization: () -> String = PasskeySystemSupport.authorizationState,
                    report: (String) -> Void = { print($0) }) -> Int32? {
        guard arguments.contains(argument) else { return nil }
        guard arguments.count == 2 else { return 64 }
        let signed = PasskeySystemSupport.browserPasskeysSigned(entitlements())
        // The provider is queried only when the system will admit the request.
        let state = signed ? authorization() : "unavailable"
        report("{\"browserPasskeys\":\(signed),\"authorization\":\"\(state)\"}")
        return signed ? 0 : 69
    }
}
