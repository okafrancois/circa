import AppKit
import CoreText

/// Shared brand font registration, with a system fallback for resource or registration failures.
public enum BrandFonts {
    private static let weightAxis = "wght".utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    public static let filenames = ["intertight.ttf", "geistmono.ttf", "gloock.ttf"]
    public static let registered: Bool = {
        var success = true
        for name in filenames {
            guard let url = BrowserText.resourceBundle?.url(forResource: name, withExtension: nil, subdirectory: "BrandFonts")
                ?? BrowserText.resourceBundle?.url(forResource: name, withExtension: nil) else { success = false; continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { success = false }
        }
        return success
    }()
    public static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard registered, let face = NSFont(name: "InterTight-Regular", size: size) ?? NSFont(name: "Inter Tight", size: size) else { return .systemFont(ofSize: size, weight: weight) }
        let value: Double = weight >= .bold ? 700 : weight >= .semibold ? 600 : weight >= .medium ? 500 : 400
        let descriptor = face.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [NSNumber(value: weightAxis): NSNumber(value: value)]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? face
    }
    public static func mono(_ size: CGFloat) -> NSFont {
        guard registered else { return .monospacedSystemFont(ofSize: size, weight: .medium) }
        return NSFont(name: "GeistMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .medium)
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

public enum BrandTextStyle {
    case title
    public func font(size: CGFloat) -> NSFont {
        switch self {
        case .title:
            guard BrandFonts.registered else { return .systemFont(ofSize: size) }
            return NSFont(name: "Gloock-Regular", size: size) ?? .systemFont(ofSize: size)
        }
    }
}
