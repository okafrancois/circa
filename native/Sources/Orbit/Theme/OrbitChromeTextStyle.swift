import AppKit

/// Native typography for browser navigation surfaces.
enum OrbitChromeTextStyle {
    case body, caption, mono
    func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
    func attributedString(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                          attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var attributes = attributes
        attributes[.font] = font(size: size, weight: weight)
        return NSAttributedString(string: text, attributes: attributes)
    }
}
