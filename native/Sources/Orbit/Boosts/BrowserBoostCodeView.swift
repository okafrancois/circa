import AppKit

/// The code destination is intentionally disabled until editing behavior is specified.
@MainActor
final class BrowserBoostCodeView: NSView {
    var onBack: (() -> Void)?
    private let canvas = LibraryFlippedView()
    private let css = BoostButton(title: uiText("CSS"))
    private let js = BoostButton(title: uiText("JS"))
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.white.cgColor
        canvas.frame = NSRect(x: 0, y: 0, width: 480, height: 588)
        addSubview(canvas)
        let back = BoostButton(title: uiText("←  Back")); back.fill = .clear
        back.actionBlock = { [weak self] in self?.onBack?() }
        back.frame = NSRect(x: 12, y: 6, width: 60, height: 28); canvas.addSubview(back)
        let tabs = NSView(frame: NSRect(x: 190, y: 8, width: 100, height: 24))
        tabs.wantsLayer = true; tabs.layer?.cornerRadius = 6; tabs.layer?.masksToBounds = true
        tabs.layer?.backgroundColor = NSColor(calibratedWhite: 0.9, alpha: 1).cgColor
        css.frame = NSRect(x: 0, y: 0, width: 50, height: 24)
        js.frame = NSRect(x: 50, y: 0, width: 50, height: 24)
        css.fill = NSColor(calibratedWhite: 0.78, alpha: 1); js.fill = .clear
        css.actionBlock = { [weak self] in self?.selectCSS(true) }
        js.actionBlock = { [weak self] in self?.selectCSS(false) }
        tabs.addSubview(css); tabs.addSubview(js); canvas.addSubview(tabs)
        let content = NSView(frame: NSRect(x: 0, y: 40, width: 480, height: 480))
        content.wantsLayer = true; content.layer?.backgroundColor = NSColor(srgbRed: 0.125, green: 0.13, blue: 0.15, alpha: 1).cgColor
        canvas.addSubview(content)
        let message = NSTextField(wrappingLabelWithString: uiText("Internal debugging pages are currently disabled."))
        message.font = .systemFont(ofSize: 24, weight: .semibold)
        message.textColor = NSColor(srgbRed: 0.62, green: 0.64, blue: 0.66, alpha: 1); message.alignment = .center
        message.frame = NSRect(x: 12, y: 124, width: 456, height: 90); canvas.addSubview(message)
    }
    private func selectCSS(_ selected: Bool) {
        css.fill = selected ? NSColor(calibratedWhite: 0.78, alpha: 1) : .clear
        js.fill = selected ? .clear : NSColor(calibratedWhite: 0.78, alpha: 1)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        canvas.frame.origin.x = (bounds.width - 480) / 2
    }
}
