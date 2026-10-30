import BrowserCore
import Foundation

enum ArcPasswordImportText {
    static func result(_ counts: ArcPasswordImportJournal.Counts, restored: Bool) -> String {
        var lines: [String] = []
        if restored {
            if counts.removed > 0 { lines.append(uiText("%d imported passwords removed", count: counts.removed)) }
            if counts.retained > 0 { lines.append(uiText("%d edited passwords kept", count: counts.retained)) }
        } else {
            if counts.added > 0 { lines.append(uiText("%d passwords added", count: counts.added)) }
            if counts.alreadyPresent > 0 { lines.append(uiText("%d passwords already in Orbit", count: counts.alreadyPresent)) }
            if counts.kept > 0 { lines.append(uiText("%d passwords not replaced (Orbit's version kept)", count: counts.kept)) }
            if counts.skipped > 0 { lines.append(uiText("%d passwords skipped", count: counts.skipped)) }
        }
        return lines.joined(separator: "\n")
    }
}
