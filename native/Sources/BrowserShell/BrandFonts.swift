import AppKit
import CoreText

/// Bundled brand typography and vector mark.
public enum BrandFonts {
    private static let registration: Void = {
        for name in ["BricolageGrotesque-ExtraBold", "DMSans-Regular", "DMSans-Medium", "DMSans-SemiBold", "DMSans-Bold", "DMMono-Regular"] {
            if let url = BrowserText.resourceBundle?.url(forResource: name, withExtension: "ttf", subdirectory: "BrandFonts")
                ?? BrowserText.resourceBundle?.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    static func registered(_ name: String, size: CGFloat) -> NSFont? {
        _ = registration
        return NSFont(name: name, size: size)
    }

    public static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        BrandTextStyle.ui.font(size: size, weight: weight)
    }
    /// Branded copy uses the bundled text family.
    public static func onboardingBody(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        BrandTextStyle.body.font(size: size, weight: weight)
    }
    public static func mono(_ size: CGFloat) -> NSFont {
        BrandTextStyle.mono.font(size: size)
    }
    public static var markURL: URL? {
        BrowserText.resourceBundle?.url(forResource: "mark", withExtension: "pdf", subdirectory: "BrandFonts")
            ?? BrowserText.resourceBundle?.url(forResource: "mark", withExtension: "pdf")
    }
    public static var mark: NSImage? {
        guard let url = markURL else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Browser controls retain native type; copy, labels and headings use brand roles.
public enum BrandTextStyle: CaseIterable {
    case body, ui, caption, mono, title

    public func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name: String
        switch self {
        case .ui: return .systemFont(ofSize: size, weight: weight)
        case .title: name = "BricolageGrotesque-ExtraBold"
        case .mono: name = "DMMono-Regular"
        case .body, .caption:
            let style = weight >= .bold ? "Bold" : weight >= .semibold ? "SemiBold" : weight >= .medium ? "Medium" : "Regular"
            name = "DMSans-" + style
        }
        return BrandFonts.registered(name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    public func tracking(size: CGFloat) -> CGFloat { self == .title ? -0.045 * size : 0 }

    /// Shortcut letters, digits and modifier symbols share the system face.
    public func attributedString(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                                 attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var attributes = attributes
        attributes[.font] = font(size: size, weight: weight)
        if self == .title { attributes[.kern] = tracking(size: size) }
        return NSAttributedString(string: text, attributes: attributes)
    }
}
