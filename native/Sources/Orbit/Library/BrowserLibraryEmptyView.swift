import AppKit
import BrowserShell

/// Home's empty result: a low-contrast 48-point glyph above a centered message.
@MainActor
final class BrowserLibraryEmptyView: NSView {
    private let icon = NSImageView()
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    private var messageGap: NSLayoutConstraint!
    let message = NSTextField(wrappingLabelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        message.font = BrandTextStyle.title.font(size: 14)
        message.alignment = .center
        for view in [icon, message] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 48)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 48)
        messageGap = message.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 104),
            icon.topAnchor.constraint(equalTo: topAnchor), icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconWidth, iconHeight, messageGap,
            message.leadingAnchor.constraint(equalTo: leadingAnchor), message.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        updateColors()
    }
    required init?(coder: NSCoder) { nil }
    func configure(symbol: String, title: String, query: String = "", largeGlyph: Bool = false) {
        iconWidth.constant = largeGlyph ? 56 : 48
        iconHeight.constant = largeGlyph ? 56 : 48
        messageGap.constant = largeGlyph ? 12 : 16
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
