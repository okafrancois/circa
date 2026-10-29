import Foundation

/// Executed before the launcher, AppKit, CEF, defaults, Keychain or session storage.
/// Launch the executable directly: LaunchServices could route to an existing personal instance.
@MainActor
enum BrowserSyncLaunchVerification {
    static func run(arguments: [String],
                    availability: () -> Bool = { BrowserSyncRuntime().available },
                    report: (String) -> Void = { print($0) }) -> Int32? {
        guard arguments.contains("--orbit-verify-icloud") else { return nil }
        // Fail closed even when combined with ordinary launch options. No configuration or
        // storage is resolved on this path, and no CKContainer is constructed.
        guard arguments.count == 2 else { return 64 }
        let available = availability()
        report("{\"icloudAvailable\":\(available),\"storageInitialized\":false}")
        return available ? 0 : 69
    }
}
