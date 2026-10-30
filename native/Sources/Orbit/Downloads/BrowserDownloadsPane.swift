import AppKit

/// Embeddable Downloads category; the Library owns navigation when embedded.
@MainActor
final class BrowserDownloadsPane: NSView, NSSearchFieldDelegate {
    private var railWidth: NSLayoutConstraint!
    private let rail = NSView()
    private var searchTop: NSLayoutConstraint!
    func setLibraryEmbedded() {
        rail.isHidden = true
        railWidth.constant = 0
        titleLabel.isHidden = true
        profileLabel.isHidden = true
        searchTop.isActive = false
        searchField.topAnchor.constraint(equalTo: topAnchor, constant: 10).isActive = true
    }
    let list = BrowserDownloadsView()
    var onBack: (() -> Void)?
    var onSearch: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: uiText("Downloads"))
    private let profileLabel = NSTextField(labelWithString: "")
    let searchField = BrowserLibrarySearchField()
    private let filterButton = BrowserLibraryFilterButton()
    var query: String { searchField.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        railWidth = rail.widthAnchor.constraint(equalToConstant: 64)
        let category = NSImageView(image: OrbitIcon.image(sfName: "arrow.down.circle.fill", pointSize: 20, accessibilityDescription: uiText("Downloads"))!)
        category.contentTintColor = .labelColor
        let back = NSButton(image: OrbitIcon.image(sfName: "arrow.left", pointSize: 20, accessibilityDescription: uiText("Back to Tabs"))!, target: self, action: #selector(goBack(_:)))
        back.isBordered = false
        back.toolTip = uiText("Back to Tabs")
        for control in [category, back] { control.translatesAutoresizingMaskIntoConstraints = false; rail.addSubview(control) }
        let results = NSView()
        titleLabel.font = OrbitTokens.Typography.commandBarInput
        profileLabel.font = OrbitTokens.Typography.menuShortcut
        profileLabel.textColor = OrbitTokens.Color.Text.secondary
        searchField.placeholderString = uiText("Search Downloads…")
        searchField.maximumRecents = 0
        searchField.recentsAutosaveName = nil
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("downloads-search")
        for view in [titleLabel, profileLabel, searchField, filterButton, list] {
            view.translatesAutoresizingMaskIntoConstraints = false
            results.addSubview(view)
        }
        for view in [rail, results] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        searchTop = searchField.topAnchor.constraint(equalTo: profileLabel.bottomAnchor, constant: 12)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor), railWidth,
            rail.topAnchor.constraint(equalTo: topAnchor), rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            category.centerXAnchor.constraint(equalTo: rail.centerXAnchor), category.topAnchor.constraint(equalTo: rail.topAnchor, constant: 52),
            back.centerXAnchor.constraint(equalTo: rail.centerXAnchor), back.bottomAnchor.constraint(equalTo: rail.bottomAnchor, constant: -16),
            results.leadingAnchor.constraint(equalTo: rail.trailingAnchor), results.trailingAnchor.constraint(equalTo: trailingAnchor),
            results.topAnchor.constraint(equalTo: topAnchor), results.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: results.leadingAnchor, constant: 16), titleLabel.topAnchor.constraint(equalTo: results.topAnchor, constant: 40),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: results.trailingAnchor, constant: -16),
            profileLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), profileLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            searchField.leadingAnchor.constraint(equalTo: results.leadingAnchor, constant: 8), searchField.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -4),
            filterButton.trailingAnchor.constraint(equalTo: results.trailingAnchor, constant: -8),
            filterButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchTop,
            list.leadingAnchor.constraint(equalTo: results.leadingAnchor), list.trailingAnchor.constraint(equalTo: results.trailingAnchor),
            list.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8), list.bottomAnchor.constraint(equalTo: results.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
    func setProfileName(_ name: String) {
        profileLabel.stringValue = name
        list.emptyQuery = searchField.stringValue
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelLibrarySearch(searchField, search: { onSearch?() }, close: { onBack?() })
            return true
        }
        return false
    }
    func controlTextDidChange(_ notification: Notification) { onSearch?() }
    @objc private func goBack(_ sender: Any?) { onBack?() }
}
