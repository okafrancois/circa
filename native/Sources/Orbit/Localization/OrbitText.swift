import Foundation
import BrowserShell

/// All app UI strings use the shared SwiftPM localization bundle.
func uiText(_ english: String) -> String { BrowserText.string(english) }

/// Let the localization's plural rules choose the phrase before inserting its count.
func uiText(_ english: String, count: Int) -> String {
    String.localizedStringWithFormat(uiText(english), count)
}

/// Interpolation happens after lookup, keeping data out of localization keys.
func uiFormat(_ english: String, _ arguments: CVarArg...) -> String {
    String(format: uiText(english), locale: Locale.current, arguments: arguments)
}
