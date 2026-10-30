import BrowserCore
import BrowserShell

enum BrowserQuickWindowArchiveSettings {
    static let choices: [BrowserAutoArchiveThreshold] = [.oneHour, .sixHours, .twelveHours]

    static func title(_ threshold: BrowserAutoArchiveThreshold) -> String {
        switch threshold {
        case .oneHour: uiText("1 hour")
        case .sixHours: uiText("6 hours")
        case .twelveHours: uiText("12 hours")
        default: uiText("Custom Delay")
        }
    }
}
