import BrowserCore
import BrowserShell
import Foundation

/// Captured before the native scope prompt so a later profile selection cannot retarget it.
struct BrowserArchiveSettingsChange: Identifiable {
    let id = UUID()
    let profile: ProfileID
    let profileName: String
    let threshold: BrowserAutoArchiveThreshold

    static func options(current: BrowserAutoArchiveThreshold?) -> [BrowserAutoArchiveThreshold] {
        var options: [BrowserAutoArchiveThreshold] = [.twelveHours, .oneDay, .sevenDays, .thirtyDays, .never]
        if let current, !options.contains(current) { options.append(current) }
        return options
    }

    static func label(_ threshold: BrowserAutoArchiveThreshold) -> String {
        switch threshold {
        case .twelveHours: return uiText("12 hours")
        case .oneDay: return uiText("24 hours")
        case .sevenDays: return uiText("7 days")
        case .thirtyDays: return uiText("30 days")
        case .never: return uiText("Never")
        default: return uiText("Custom Delay")
        }
    }

    var title: String {
        guard let interval = threshold.interval else { return uiText("Circa will never auto-archive your tabs.") }
        let label: String
        switch interval {
        case 12 * 3600: label = uiText("12 hours")
        case 24 * 3600: label = uiText("24 hours")
        case 7 * 24 * 3600: label = uiText("7 days")
        case 30 * 24 * 3600: label = uiText("30 days")
        default: label = uiText("Custom Delay")
        }
        return uiFormat("Circa will now archive your tabs after %@", label)
    }
}
