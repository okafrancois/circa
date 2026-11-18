import AppKit
import BrowserCore

/// Plain native drawing; untrusted event titles never become HTML or attributed markup.
@MainActor
final class CalendarPreviewView: NSView {
    let scroll = NSScrollView()
    private let timeline = CalendarTimelineView()
    private let gear = NSButton(title: "", target: nil, action: nil)
    private let add = SidebarPreviewAddButton(title: "", target: nil, action: nil)
    var onMenu: (() -> NSMenu?)?
    var onAdd: (() -> Void)?
    var contentHeight: CGFloat { 256 }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        scroll.documentView = timeline; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        addSubview(scroll)
        for (button, symbol, title, action) in [(gear, "gearshape.fill", uiText("Live Calendar"), #selector(showMenu)),
                                               (add, "plus", uiText("Create event"), #selector(createEvent))] {
            button.bezelStyle = .circular; button.imagePosition = .imageOnly
            button.image = OrbitIcon.image(sfName: symbol, pointSize: 15)
            button.target = self; button.action = action; button.toolTip = title; button.setAccessibilityLabel(title)
            addSubview(button)
        }
        gear.image = OrbitIcon.calendarSettingsImage()
        setAccessibilityRole(.group); setAccessibilityLabel(uiText("Live Calendar"))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func render(_ agenda: BrowserCalendarWebAgenda) {
        let first = timeline.agenda == nil
        timeline.agenda = agenda; timeline.needsDisplay = true
        needsLayout = true; layoutSubtreeIfNeeded()
        if first {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = agenda.timeZone
            scroll.contentView.scroll(to: .init(x: 0, y: CGFloat(calendar.component(.hour, from: Date())) * 41.8))
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        OrbitTokens.Color.Calendar.shell.setFill(); bounds.fill()
    }
    func clear() { timeline.agenda = nil; timeline.needsDisplay = true }
    override func layout() {
        super.layout(); scroll.frame = bounds
        timeline.frame = .init(x: 0, y: 0, width: bounds.width, height: 24 * 41.8 + 256)
        gear.frame = .init(x: bounds.width - 66, y: bounds.height - 34, width: 28, height: 28)
        add.frame = .init(x: bounds.width - 34, y: bounds.height - 34, width: 28, height: 28)
    }
    @objc private func showMenu() { onMenu?()?.popUp(positioning: nil, at: .init(x: gear.frame.minX, y: gear.frame.maxY), in: self) }
    @objc private func createEvent() { onAdd?() }
}

@MainActor
private final class CalendarTimelineView: NSView {
    var agenda: BrowserCalendarWebAgenda?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let agenda else { return }
        let pitch: CGFloat = 41.8
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let ink = OrbitTokens.Color.Text.primary
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink, .paragraphStyle: paragraph]
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: OrbitTokens.Color.Text.secondary]
        let formatter = DateFormatter(); formatter.timeZone = agenda.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "h a"
        for hour in 0..<24 {
            let y = CGFloat(hour) * pitch + 8
            NSColor.separatorColor.withAlphaComponent(0.35).setFill()
            NSRect(x: 4, y: y, width: bounds.width - 8, height: 0.5).fill()
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = agenda.timeZone
            if let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: agenda.day) {
                (formatter.string(from: date) as NSString).draw(at: .init(x: 4, y: y + 4), withAttributes: label)
            }
        }
        // Unknown durations occupy one hour row. Connected overlap groups share equal columns.
        var groups: [[BrowserCalendarWebEvent]] = []
        for event in agenda.events {
            if let last = groups.last, last.map({ $0.end ?? $0.start.addingTimeInterval(3600) }).max()! > event.start {
                groups[groups.count - 1].append(event)
            } else { groups.append([event]) }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = agenda.timeZone
        func offset(_ date: Date) -> CGFloat {
            CGFloat(calendar.component(.hour, from: date)) * pitch + CGFloat(calendar.component(.minute, from: date)) * pitch / 60 + 8
        }
        for group in groups {
            let width = (bounds.width - 54) / CGFloat(group.count)
            for (column, event) in group.enumerated() {
                let rect = NSRect(x: 49 + CGFloat(column) * width, y: offset(event.start), width: max(1, width - 1),
                                  height: max(1, CGFloat((event.end?.timeIntervalSince(event.start) ?? 3600) / 3600) * pitch - 2))
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                OrbitTokens.Color.Calendar.event.setFill(); path.fill()
                OrbitTokens.Color.Calendar.outline.setStroke(); path.lineWidth = 0.5; path.stroke()
                NSGraphicsContext.saveGraphicsState(); path.addClip()
                (event.title as NSString).draw(in: NSRect(x: rect.minX + 3, y: rect.minY + 3, width: max(0, rect.width - 6), height: 14), withAttributes: text)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        let nowY = offset(Date())
        OrbitTokens.Color.Calendar.now.setFill()
        NSRect(x: 42, y: nowY, width: bounds.width - 47, height: 1.5).fill()
        NSBezierPath(ovalIn: .init(x: 39, y: nowY - 2.5, width: 6, height: 6)).fill()
    }
}
