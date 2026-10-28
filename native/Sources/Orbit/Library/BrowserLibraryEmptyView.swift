import AppKit

/// Home's empty result: a low-contrast 48-point glyph above a centered message.
@MainActor
final class BrowserLibraryEmptyView: NSView {
    private let icon = NSImageView()
    let message = NSTextField(wrappingLabelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        message.font = .systemFont(ofSize: 14)
        message.alignment = .center
        for view in [icon, message] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 104),
            icon.topAnchor.constraint(equalTo: topAnchor), icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48), icon.heightAnchor.constraint(equalToConstant: 48),
            message.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16),
            message.leadingAnchor.constraint(equalTo: leadingAnchor), message.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        updateColors()
    }
    required init?(coder: NSCoder) { nil }
    func configure(symbol: String, title: String, query: String = "") {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 44, weight: .regular))
        message.stringValue = query.isEmpty ? title : uiFormat("No results found for\n“%@”", query)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        icon.contentTintColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.3)
        message.textColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.55)
    }
}
