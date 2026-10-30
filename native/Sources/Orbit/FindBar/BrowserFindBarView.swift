import AppKit
import BrowserShell

/// Presents native engine results; this view neither searches pages nor owns query state.
@MainActor
final class BrowserFindBarView: NSView, NSSearchFieldDelegate {
    let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let caseButton = NSButton(title: uiText("Aa"), target: nil, action: nil)
    private let closeButton = NSButton()
    var onQueryChange: ((String, Bool) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var pendingOptionsRevision: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        setAccessibilityLabel(uiText("Find in Page"))
        searchField.placeholderString = uiText("Find in Page")
        searchField.setAccessibilityIdentifier("page-find-query")
        searchField.maximumRecents = 0
        searchField.recentsAutosaveName = nil
        searchField.delegate = self
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = BrandTextStyle.mono.font(size: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .right
        statusLabel.setAccessibilityIdentifier("page-find-status")
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(previousButton, symbol: "chevron.up", label: uiText("Previous Match"), action: #selector(previous(_:)))
        configure(nextButton, symbol: "chevron.down", label: uiText("Next Match"), action: #selector(next(_:)))
        configure(closeButton, symbol: "xmark", label: uiText("Close Find"), action: #selector(close(_:)))
        caseButton.setButtonType(.pushOnPushOff)
        caseButton.isBordered = false
        caseButton.font = BrandTextStyle.ui.font(size: 11, weight: .medium)
        caseButton.target = self
        caseButton.action = #selector(changeCase(_:))
        caseButton.toolTip = uiText("Match Case")
        caseButton.setAccessibilityLabel(uiText("Match Case"))
        let controls = NSStackView(views: [searchField, statusLabel, previousButton, nextButton, caseButton, closeButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100),
            caseButton.widthAnchor.constraint(equalToConstant: 26)
        ])
        let minimumQueryWidth = searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        minimumQueryWidth.priority = .defaultHigh
        minimumQueryWidth.isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func render(query: String, matchCase: Bool, status: String, searching: Bool, canNavigate: Bool,
                replaceEditing: Bool = false) {
        let editing = window?.firstResponder === searchField.currentEditor() && searchField.currentEditor() != nil
        if !editing || replaceEditing {
            if searchField.stringValue != query { searchField.stringValue = query }
        }
        if replaceEditing { pendingOptionsRevision = nil }
        if pendingOptionsRevision == nil { caseButton.state = matchCase ? .on : .off }
        statusLabel.stringValue = status
        statusLabel.toolTip = status
        previousButton.isEnabled = canNavigate && !searching
        nextButton.isEnabled = canNavigate && !searching
    }

    func focusQuery() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func acknowledgeOptions(_ revision: UUID?) {
        guard let revision, pendingOptionsRevision == revision else { return }
        pendingOptionsRevision = nil
    }

    var caseControl: NSButton { caseButton }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === searchField else { return }
        onQueryChange?(searchField.stringValue, caseButton.state == .on)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() }
            else { onNext?() }
            return true
        }
        return false
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = OrbitIcon.image(sfName: symbol, pointSize: 14, accessibilityDescription: nil)
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @objc private func next(_ sender: Any?) { onNext?() }
    @objc private func previous(_ sender: Any?) { onPrevious?() }
    @objc private func close(_ sender: Any?) { onClose?() }
    @objc private func changeCase(_ sender: Any?) {
        pendingOptionsRevision = UUID()
        onQueryChange?(searchField.stringValue, caseButton.state == .on)
    }
}
