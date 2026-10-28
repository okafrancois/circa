import AppKit

/// Calendar headings must change even when no new history query or archive revision arrives.
@MainActor
final class BrowserLibraryDateObserver: NSObject {
    private var timer: Timer?
    private let now: () -> Date
    private var lastDay: Date
    var onChange: (() -> Void)?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        lastDay = Calendar.current.startOfDay(for: now())
        super.init()
        for name in [NSNotification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged,
                     NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(notificationChanged(_:)), name: name, object: nil)
        }
    }
    func setAttached(_ attached: Bool) {
        timer?.invalidate(); timer = nil
        guard attached else { return }
        let now = now()
        let next = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(86400)
        timer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSince(now) + 1), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshCalendar() }
        }
    }
    @objc nonisolated private func notificationChanged(_ notification: Notification) {
        let force = notification.name != .NSCalendarDayChanged
        Task { @MainActor [weak self] in self?.refreshCalendar(force: force) }
    }
    /// Timer and day-change notifications describe the same transition. Only one refresh is
    /// published per local day; time-zone/locale changes always invalidate formatting.
    func refreshCalendar(force: Bool = false) {
        let day = Calendar.current.startOfDay(for: now())
        if force || day != lastDay {
            lastDay = day
            onChange?()
        }
        if timer != nil { setAttached(true) }
    }

}

@MainActor
func cancelLibrarySearch(_ field: NSSearchField, search: () -> Void, close: () -> Void) {
    if field.stringValue.isEmpty { close() }
    else { field.stringValue = ""; search() }
}
