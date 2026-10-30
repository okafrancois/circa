import AppKit
import BrowserCore

/// Shared bounded caches: swipe redraws reuse symbol images instead of rasterizing them again.
@MainActor
enum SpaceIconImages {
    private static let templates = NSCache<NSString, NSImage>()
    private static let tinted = NSCache<NSString, NSImage>()
    private static let graphemes = NSCache<NSString, NSImage>()

    static func tabImage(_ choice: BrowserSpaceIcon?) -> NSImage? {
        guard let choice, choice != .none else { return nil }
        if case .systemSymbol(let name) = choice {
            return OrbitIcon.image(sfName: name, pointSize: 16, accessibilityDescription: nil)
        }
        guard case .grapheme(let value) = choice else { return nil }
        let key = "tab:" + value as NSString
        if let image = graphemes.object(forKey: key) { return image }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let text = NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 16)])
            let size = text.size()
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        graphemes.countLimit = 128
        graphemes.setObject(image, forKey: key)
        return image
    }

    static func template(_ identifier: String, pointSize: CGFloat) -> NSImage? {
        guard BrowserSpaceIcon.isValidSymbolIdentifier(identifier) else { return nil }
        let key = "\(identifier):\(pointSize)" as NSString
        if let image = templates.object(forKey: key) { return image }
        guard let base = NSImage(systemSymbolName: identifier, accessibilityDescription: nil),
              let image = base.withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)) else { return nil }
        image.isTemplate = true
        templates.countLimit = 192
        templates.setObject(image, forKey: key)
        return image
    }

    static func symbol(_ identifier: String, pointSize: CGFloat, tint: NSColor,
                       active: Bool, appearance: NSAppearance) -> NSImage? {
        guard let source = template(identifier, pointSize: pointSize),
              let resolved = tint.resolved(for: appearance).usingColorSpace(.sRGB) else { return nil }
        let color: NSColor
        if active { color = resolved }
        else {
            // Preserve linear luminance, so the footer's contrast/opacity policy still applies.
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let y = 0.2126 * linear(resolved.redComponent) + 0.7152 * linear(resolved.greenComponent) + 0.0722 * linear(resolved.blueComponent)
            let gray = y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
            color = NSColor(srgbRed: gray, green: gray, blue: gray, alpha: resolved.alphaComponent)
        }
        let key = "\(identifier):\(pointSize):\(color.redComponent):\(color.greenComponent):\(color.blueComponent):\(color.alphaComponent)" as NSString
        if let image = tinted.object(forKey: key) { return image }
        let image = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        tinted.countLimit = 256
        tinted.setObject(image, forKey: key)
        return image
    }

    static func label(_ choice: BrowserSpaceIcon) -> String {
        switch choice {
        case .none: uiText("No Icon")
        case .grapheme(let value): value
        case .systemSymbol(let identifier): SpaceSymbolCatalog.title(for: identifier)
        }
    }

    /// Library and Settings use the same native projection; no emoji can accompany a symbol.
    static func view(_ choice: BrowserSpaceIcon, pointSize: CGFloat = 22) -> NSView {
        let view: NSImageView
        if case .systemSymbol(let name) = choice, let image = template(name, pointSize: pointSize) {
            view = NSImageView(image: image)
            view.contentTintColor = OrbitTokens.Color.Text.primary
        } else if case .grapheme(let value) = choice {
            let key = "\(pointSize):\(value)" as NSString
            let image: NSImage
            if let cached = graphemes.object(forKey: key) { image = cached }
            else {
                let text = NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: pointSize)])
                image = NSImage(size: text.size(), flipped: false) { _ in text.draw(at: .zero); return true }
                graphemes.countLimit = 128
                graphemes.setObject(image, forKey: key)
            }
            view = NSImageView(image: image)
        } else {
            view = NSImageView(image: template("circle", pointSize: pointSize) ?? NSImage())
            view.contentTintColor = OrbitTokens.Color.Text.primary
        }
        view.setAccessibilityLabel(label(choice))
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }
}
