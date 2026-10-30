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
            if counts.alreadyPresent > 0 { lines.append(uiFormat("%d passwords already in %@", counts.alreadyPresent, ProductIdentity.displayName)) }
            if counts.kept > 0 { lines.append(uiFormat("%d passwords not replaced (%@'s version kept)", counts.kept, ProductIdentity.displayName)) }
            if counts.skipped > 0 { lines.append(uiText("%d passwords skipped", count: counts.skipped)) }
        }
        return lines.joined(separator: "\n")
    }
}
