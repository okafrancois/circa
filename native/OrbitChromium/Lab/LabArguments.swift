import Foundation

/// Arguments of a synthetic laboratory run. The runner script builds them; nothing selects a
/// personal profile: the root must be a fresh directory carrying the laboratory marker.
struct LabArguments {
    let root: URL
    let origin: String
    let extensionLoaded: Bool
    let asyncHold: Bool
    /// `--use-fake-device-for-media-stream` (read by Chromium itself): synthetic capture devices.
    let fakeMediaDevices: Bool
    /// Relaunch phase: reuse the root and the profile identity of an earlier run.
    let restoreProfile: UUID?

    let visibleInputOnly: Bool
    let visibleInputSeconds: Int
    /// CHROMIUM-APP-R2 (review H3): only a browser whose close never completes, then the quit.
    let quitStallOnly: Bool

    static func parse(_ input: [String] = CommandLine.arguments) -> LabArguments? {
        var root: String?, origin: String?, mock = false, extensionLoaded = false, asyncHold = false, fakeMedia = false
        var restoreProfile: UUID?
        var visibleInputOnly = false, visibleInputSeconds = 30, hasVisibleDuration = false, quitStallOnly = false
        for argument in input.dropFirst() {
            if argument == "--lab-visible-input-only" { visibleInputOnly = true }
            else if argument == "--lab-quit-stall-only" { quitStallOnly = true }
            else if argument.hasPrefix("--lab-visible-input-seconds=") {
                guard let seconds = Int(argument.dropFirst("--lab-visible-input-seconds=".count)) else { return nil }
                visibleInputSeconds = seconds
                hasVisibleDuration = true
            }
            else if argument.hasPrefix("--lab-root=") { root = String(argument.dropFirst(11)) }
            else if argument.hasPrefix("--fixture-origin=") { origin = String(argument.dropFirst(17)) }
            else if argument == "--use-mock-keychain" { mock = true }
            else if argument.hasPrefix("--load-extension=") { extensionLoaded = true }
            else if argument == "--lab-async-hold" { asyncHold = true }
            else if argument == "--use-fake-device-for-media-stream" { fakeMedia = true }
            // Real-device or auto-accepting capture flags are never allowed in the laboratory.
            else if argument.hasPrefix("--use-fake-ui-for-media-stream") || argument.hasPrefix("--user-data-dir") { return nil }
            else if argument.hasPrefix("--lab-restore-profile=") { restoreProfile = UUID(uuidString: String(argument.dropFirst(22))) }
        }
        guard (15...60).contains(visibleInputSeconds), (!hasVisibleDuration || visibleInputOnly),
              (!visibleInputOnly || (!asyncHold && restoreProfile == nil)),
              (!quitStallOnly || (!visibleInputOnly && !asyncHold && restoreProfile == nil)),
              mock, let root, let origin, origin.hasPrefix("http://127.0.0.1:"), !origin.hasSuffix(":4318"),
              root.hasPrefix("/"), (try? String(contentsOfFile: root + "/.orbit-chromium-lab", encoding: .utf8))
                == "orbit-chromium-lab-v1\n" else { return nil }
        return LabArguments(root: URL(fileURLWithPath: root), origin: origin, extensionLoaded: extensionLoaded,
                            asyncHold: asyncHold, fakeMediaDevices: fakeMedia, restoreProfile: restoreProfile,
                            visibleInputOnly: visibleInputOnly, visibleInputSeconds: visibleInputSeconds,
                            quitStallOnly: quitStallOnly)
    }
}

/// Activation may settle once; losing focus after confirmation never requests activation again.
enum VisibleInputReadiness {
    enum Decision { case waiting, ready, abort }
    static func decision(ownerStable: Bool, key: Bool, active: Bool, confirmed: Bool) -> Decision {
        guard ownerStable else { return .abort }
        if key && active { return .ready }
        return confirmed ? .abort : .waiting
    }
}
