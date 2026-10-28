import AppKit
import BrowserCore

func libraryHistoryDeletionDescription(_ deletion: BrowserHistoryDeletion?) -> String {
    func date(_ value: Date) -> String { DateFormatter.localizedString(from: value, dateStyle: .medium, timeStyle: .medium) }
    switch deletion {
    case .site(let host): return String.localizedStringWithFormat(libraryText("deleteHost", "Site: %@"), host)
    case .interval(let interval):
        return String.localizedStringWithFormat(libraryText("deleteInterval", "From %@ to %@ (end excluded)"), date(interval.start), date(interval.end))
    case .lastHour(let now):
        return String.localizedStringWithFormat(libraryText("deleteLastHour", "Since %@ (last hour)"), date(now.addingTimeInterval(-3600)))
    case .lastDay(let now):
        return String.localizedStringWithFormat(libraryText("deleteLastDay", "Since %@ (last 24 hours)"), date(now.addingTimeInterval(-86400)))
    case .all: return libraryText("deleteAllHistory", "All History")
    case .visit: return libraryText("deleteVisit", "Delete Visit")
    case nil: return libraryText("deleteCustomRange", "Custom Date Range (start included, end excluded)")
    }
}
