import AppKit

/// Date-range confirmation input. The destructive button stays disabled for an empty/reversed
/// interval; the storage API uses an inclusive start and exclusive end.
@MainActor
final class BrowserLibraryDateRangeView: NSStackView {
    let start = NSDatePicker()
    let end = NSDatePicker()
    var onChange: ((DateInterval?) -> Void)?
    weak var confirmButton: NSButton?
    var interval: DateInterval? {
        guard start.dateValue < end.dateValue else { return nil }
        return DateInterval(start: start.dateValue, end: end.dateValue)
    }

    init(now: Date = Date()) {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading
        start.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        end.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        start.dateValue = Calendar.current.startOfDay(for: now); end.dateValue = now
        let from = libraryText("fromInclusive", "From (inclusive)")
        let to = libraryText("toExclusive", "To (exclusive)")
        start.setAccessibilityLabel(from); end.setAccessibilityLabel(to)
        for view in [NSTextField(labelWithString: from), start, NSTextField(labelWithString: to), end] { addArrangedSubview(view) }
        for picker in [start, end] { picker.target = self; picker.action = #selector(validateInterval) }
    }
    required init?(coder: NSCoder) { nil }
    @objc func validateInterval() {
        confirmButton?.isEnabled = interval != nil
        onChange?(interval)
    }
}
