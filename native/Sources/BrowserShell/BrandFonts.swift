import AppKit
import CoreText

/// Shared brand font registration, with a system fallback for resource or registration failures.
public enum BrandFonts {
    private static let weightAxis = "wght".utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    public static let filenames = ["intertight.ttf", "geistmono.ttf", "gloock.ttf"]
    private static let registration: (succeeded: Bool, attempts: Int) = {
        var success = true
        var attempts = 0
        for name in filenames {
            guard let url = BrowserText.resourceBundle?.url(forResource: name, withExtension: nil, subdirectory: "BrandFonts")
                ?? BrowserText.resourceBundle?.url(forResource: name, withExtension: nil) else { success = false; continue }
            attempts += 1
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { success = false }
        }
        return (success, attempts)
    }()
    public static var registered: Bool { registration.succeeded }
    static var registrationAttempts: Int { registration.attempts }
    public static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard registered, let face = NSFont(name: "InterTight-Regular", size: size) ?? NSFont(name: "Inter Tight", size: size) else { return .systemFont(ofSize: size, weight: weight) }
        return withWeight(weight, font: face)
    }
    static func withWeight(_ weight: NSFont.Weight, font: NSFont) -> NSFont {
        let value: Double = weight >= .bold ? 700 : weight >= .semibold ? 600 : weight >= .medium ? 500 : 400
        let descriptor = font.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [NSNumber(value: weightAxis): NSNumber(value: value)]
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
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

/// All Orbit-drawn text uses these roles. Native system panels keep AppKit's typography.
public enum BrandTextStyle: CaseIterable {
    case body, ui, caption, mono, title

    public func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        resolvedFont(size: size, weight: weight, registrationAvailable: BrandFonts.registered)
    }

    /// Injectable availability makes failure handling testable without unregistering process fonts.
    func resolvedFont(size: CGFloat, weight: NSFont.Weight = .regular, registrationAvailable: Bool,
                      lookup: (String, CGFloat) -> NSFont? = { NSFont(name: $0, size: $1) }) -> NSFont {
        let fallback = self == .mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                                    : NSFont.systemFont(ofSize: size, weight: weight)
        guard registrationAvailable else { return fallback }
        switch self {
        case .body, .ui, .caption: return BrandFonts.ui(size, weight: weight)
        case .mono:
            guard let face = lookup("GeistMono-Regular", size) else { return fallback }
            return BrandFonts.withWeight(weight, font: face)
        case .title: return lookup("Gloock-Regular", size) ?? fallback
        }
    }

    /// Shortcut letters and numbers use the mono face; modifier symbols retain macOS glyphs.
    public func attributedString(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                                 attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var attributes = attributes
        attributes[.font] = font(size: size, weight: weight)
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        if self == .mono {
            for range in text.ranges(of: /[⌘⇧⌥⌃]/) {
                result.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: weight),
                                    range: NSRange(range, in: text))
            }
        }
        return result
    }
}
