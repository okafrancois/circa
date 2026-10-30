import AppKit

/// Shared system typography and the unchanged brand mark.
public enum BrandFonts {
    public static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        BrandTextStyle.ui.font(size: size, weight: weight)
    }
    /// Onboarding copy and controls share the system face used by browser chrome.
    public static func onboardingBody(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
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

/// Browser text uses system roles; selected branded headings use the display title role.
public enum BrandTextStyle: CaseIterable {
    case body, ui, caption, mono, title

    public func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: self == .title ? .bold : weight)
    }

    public func tracking(size: CGFloat) -> CGFloat { self == .title ? -0.02 * size : 0 }

    /// Shortcut letters, digits and modifier symbols share the system face.
    public func attributedString(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                                 attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var attributes = attributes
        attributes[.font] = font(size: size, weight: weight)
        if self == .title { attributes[.kern] = tracking(size: size) }
        return NSAttributedString(string: text, attributes: attributes)
    }
}
