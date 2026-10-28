import AppKit
import BrowserCore
import BrowserEngine

/// Observed in Developer Mode shows a 40 pt content toolbar; the sidebar keeps
/// its host-only address. Its URL is selectable and uses the same navigation action as the pill.
@MainActor
final class BrowserDeveloperToolbar: NSView {
    let address = NSTextField()
    private let actions = NSStackView()
    private let extensions = NSStackView()
    private var extensionButtons: [String: SiteControlButton] = [:]
    var onNavigate: ((String) -> Void)?
    var onPanel: ((BrowserDeveloperPanel) -> Void)?
    var onExtensions: (() -> Void)?
    var onSplit: (() -> Void)?
    var onExtension: ((String, NSButton) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 40))
        setAccessibilityIdentifier("developer-toolbar")
        wantsLayer = true
        address.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        address.isBordered = false; address.isBezeled = false; address.drawsBackground = false
        address.focusRingType = .none
        address.lineBreakMode = .byTruncatingMiddle
        address.setAccessibilityIdentifier("developer-url")
        address.target = self; address.action = #selector(navigate)
        address.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.orientation = .horizontal; actions.spacing = 0
        addSubview(address); addSubview(actions)
        NSLayoutConstraint.activate([
            address.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            address.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -10),
            address.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        addButton("link", label: uiText("Copy Link"), id: "developer-copy") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address.stringValue, forType: .string)
        }
        addButton("terminal", label: uiText("Toggle Console"), id: "developer-console") { [weak self] in self?.onPanel?(.console) }
        addButton("network", label: uiText("Toggle Network Panel"), id: "developer-network") { [weak self] in self?.onPanel?(.network) }
        addButton("scope", label: uiText("Inspect Element"), id: "developer-inspect") { [weak self] in self?.onPanel?(.elements) }
        addButton("puzzlepiece.extension", label: uiText("Extensions Menu"), id: "developer-extensions") { [weak self] in self?.onExtensions?() }
        extensions.orientation = .horizontal; extensions.spacing = 0
        actions.addArrangedSubview(extensions)
        addButton("rectangle.split.2x1", label: uiText("Split View Menu"), id: "developer-split") { [weak self] in self?.onSplit?() }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func navigate() { onNavigate?(address.stringValue) }
    private func addButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) {
        let button = SiteControlButton("", identifier: id, onPress: action)
        button.image = OrbitGlyph.symbol(symbol, pointSize: 17)
        button.setAccessibilityLabel(label); button.toolTip = label
        button.isBordered = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        actions.addArrangedSubview(button)
    }
    func update(url: URL?) {
        if address.currentEditor() == nil { address.stringValue = url?.absoluteString ?? "" }
    }
    func updateExtensions(_ items: [BrowserExtensionSummary]) {
        let ids = Set(items.map(\.id))
        for id in Array(extensionButtons.keys) where !ids.contains(id) {
            extensionButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for item in items {
            let button: SiteControlButton
            if let existing = extensionButtons[item.id] { button = existing }
            else {
                let created = SiteControlButton("", identifier: "developer-extension-" + item.id, onPress: {})
                created.onPress = { [weak self, weak created] in
                    guard let created else { return }; self?.onExtension?(item.id, created)
                }
                created.isBordered = false
                created.imageScaling = .scaleProportionallyDown
                created.widthAnchor.constraint(equalToConstant: 28).isActive = true
                created.heightAnchor.constraint(equalToConstant: 28).isActive = true
                extensionButtons[item.id] = created
                extensions.addArrangedSubview(created)
                button = created
            }
            button.setAccessibilityLabel(item.name); button.toolTip = item.name
            if let encoded = item.iconPNGBase64, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
                image.size = NSSize(width: 16, height: 16); button.image = image
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.07).setFill(); bounds.fill()
    }
}
