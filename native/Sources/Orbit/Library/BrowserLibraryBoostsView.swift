import AppKit
import BrowserShell
import BrowserCore

@MainActor
final class BrowserLibraryBoostsView: NSView, NSSearchFieldDelegate {
    let searchField = BrowserLibrarySearchField()
    private let scroll = BrowserGestureScrollView()
    private let list = LibraryFlippedView()
    private let empty = BrowserLibraryEmptyView()
    private var items: [BrowserBoost] = []
    private var profile: ProfileID?
    private var rows: [BrowserBoostID: BrowserLibraryBoostRow] = [:]
    private(set) var displayed: [BrowserBoost] = []
    var onOpen: ((BrowserBoost, ProfileID) -> Void)?
    var onBack: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.placeholderString = uiText("Search Boosts…")
        searchField.delegate = self; searchField.setAccessibilityIdentifier("library-boosts-search")
        BrowserLibraryStyle.configure(scroll); scroll.documentView = list
        for view in [searchField, scroll, empty] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        searchField.frame = NSRect(x: 8, y: 10, width: max(0, bounds.width - 16), height: 36)
        scroll.frame = NSRect(x: 0, y: 52, width: bounds.width, height: max(0, bounds.height - 52))
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, CGFloat(displayed.count) * 66 + 12))
        for (index, boost) in displayed.enumerated() {
            rows[boost.id]?.frame = NSRect(x: 12, y: 8 + CGFloat(index) * 66, width: max(0, list.bounds.width - 24), height: 58)
        }
        empty.frame = NSRect(x: 16, y: bounds.height / 2 - 32, width: max(0, bounds.width - 32), height: 164)
    }
    func selectProfile(_ profile: ProfileID) {
        guard self.profile != profile else { return }
        clear(); self.profile = profile; filter()
    }
    func render(_ items: [BrowserBoost], profile: ProfileID) {
        selectProfile(profile)
        self.items = items; filter()
    }
    func clear() {
        profile = nil; items = []; displayed = []; searchField.stringValue = ""
        for row in rows.values { row.removeFromSuperview() }; rows.removeAll()
    }
    func controlTextDidChange(_ notification: Notification) { filter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText(), selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelLibrarySearch(searchField, search: { self.filter() }, close: { self.onBack?() }); return true
    }
    private func filter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        displayed = items.filter { Self.matches($0, query: query) }
        let ids = Set(items.map(\.id)), visible = Set(displayed.map(\.id))
        for id in Array(rows.keys) where !ids.contains(id) { rows.removeValue(forKey: id)?.removeFromSuperview() }
        for (id, row) in rows { row.isHidden = !visible.contains(id) }
        for boost in displayed {
            let row = rows[boost.id] ?? BrowserLibraryBoostRow()
            row.boost = boost
            row.actionBlock = { [weak self] in guard let self, let profile else { return }; onOpen?(boost, profile) }
            if row.superview == nil { list.addSubview(row); rows[boost.id] = row }
        }
        scroll.isHidden = displayed.isEmpty
        empty.isHidden = !displayed.isEmpty
        empty.message.font = BrandTextStyle.ui.font(size: 16, weight: .semibold)
        empty.configure(symbol: "paintbrush.pointed", title: uiText("Nothing Boosted Yet!"), query: query)
        needsLayout = true
    }
    static func matches(_ boost: BrowserBoost, query: String) -> Bool {
        query.isEmpty || [boost.title, boost.hostPattern.host].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

@MainActor
private final class BrowserLibraryBoostRow: NSButton {
    var boost: BrowserBoost? { didSet { setAccessibilityLabel(boost?.title); needsDisplay = true } }
    var actionBlock: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; title = ""; target = self; action = #selector(open)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }
    @objc private func open() { actionBlock?() }
    override func draw(_ dirtyRect: NSRect) {
        guard let boost else { return }
        NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 5, width: 44, height: 44), xRadius: 10, yRadius: 10).fill()
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 3, y: 8, width: 38, height: 38), xRadius: 8, yRadius: 8).fill()
        (boost.title as NSString).draw(at: NSPoint(x: 52, y: 27), withAttributes: [.font: BrandTextStyle.ui.font(size: 14), .foregroundColor: BrowserLibraryStyle.foreground.withAlphaComponent(0.85)])
        (boost.hostPattern.host as NSString).draw(at: NSPoint(x: 52, y: 10), withAttributes: [.font: BrandTextStyle.ui.font(size: 12), .foregroundColor: BrowserLibraryStyle.foreground.withAlphaComponent(0.55)])
    }
}
