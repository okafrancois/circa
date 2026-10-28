import AppKit

/// The trailing pager page previews the existing Space creation flow. It never allocates a
/// Space while the finger is down; releasing onto it opens the window's creation form.
@MainActor
final class SidebarNewSpacePageView: NSView {
    private static let illustrationGlyphs = "🌴💻🏡"
    private let illustration = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: uiText("Create a Space"))
    private let detail = NSTextField(wrappingLabelWithString: uiText("Separate your tabs for life, work, projects, and more."))
    private let button = NSButton(title: uiText("Create Space"), target: nil, action: nil)
    var onCreate: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        illustration.stringValue = Self.illustrationGlyphs
        illustration.font = .systemFont(ofSize: 34)
        title.font = .systemFont(ofSize: 16, weight: .bold)
        detail.font = .systemFont(ofSize: 14, weight: .medium)
        for field in [illustration, title, detail] {
            field.alignment = .center
            field.textColor = OrbitTokens.Color.Text.primary
            addSubview(field)
        }
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(create)
        addSubview(button)
        setAccessibilityIdentifier("space-pager-create")
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    @objc private func create() { onCreate?() }

    override func layout() {
        super.layout()
        illustration.frame = NSRect(x: 12, y: 32, width: max(0, bounds.width - 24), height: 58)
        title.frame = NSRect(x: 12, y: 100, width: max(0, bounds.width - 24), height: 24)
        detail.frame = NSRect(x: 22, y: 132, width: max(0, bounds.width - 44), height: 58)
        button.frame = NSRect(x: 12, y: max(210, bounds.height - 64), width: max(0, bounds.width - 24), height: 36)
    }
}
