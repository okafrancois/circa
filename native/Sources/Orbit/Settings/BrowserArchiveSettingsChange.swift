import BrowserCore
import BrowserShell
import Foundation

/// Captured before the native scope prompt so a later profile selection cannot retarget it.
struct BrowserArchiveSettingsChange: Identifiable {
    let id = UUID()
    let profile: ProfileID
    let profileName: String
    let threshold: BrowserAutoArchiveThreshold

    var title: String {
        guard let interval = threshold.interval else { return uiText("Orbit will never auto-archive your tabs.") }
        let label: String
        switch interval {
        case 12 * 3600: label = uiText("12 hours")
        case 24 * 3600: label = uiText("24 hours")
        case 7 * 24 * 3600: label = uiText("7 days")
        case 30 * 24 * 3600: label = uiText("30 days")
        default: label = uiText("Custom Delay")
        }
        return uiFormat("Orbit will now archive your tabs after %@", label)
    }
}
