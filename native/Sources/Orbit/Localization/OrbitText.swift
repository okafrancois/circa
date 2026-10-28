import Foundation
import BrowserShell

/// All app UI strings use the shared SwiftPM localization bundle.
func uiText(_ english: String) -> String { BrowserText.string(english) }

/// Interpolation happens after lookup, keeping data out of localization keys.
func uiFormat(_ english: String, _ arguments: CVarArg...) -> String {
    String(format: uiText(english), locale: Locale.current, arguments: arguments)
}
