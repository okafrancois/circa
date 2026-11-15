import Foundation

/// Conservative IDN display policy for hosts shown outside the engine's own formatter
/// (palette, quick window and history rows). Each label keeps its ASCII (punycode) form
/// unless its Unicode form is clearly safe:
/// - Latin labels may only add common precomposed letters with visible diacritics.
/// - Cyrillic and Greek labels must be single-script and contain at least one letter that
///   does not look like a Latin letter (whole-script lookalikes stay ASCII).
/// - Han, Hiragana, Katakana, Bopomofo and Hangul may mix as in Japanese, Chinese and Korean,
///   without ASCII letters and without isolated dash- or slash-like characters.
/// Every other script, non-ASCII digit, symbol or combining mark keeps the ASCII form.
public enum BrowserHostDisplay {
    /// ASCII host used for matching and identity; lowercased, IDNA-encoded.
    public static func asciiHost(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (url.host ?? "").lowercased() }
        return asciiHost(components) ?? (url.host ?? "").lowercased()
    }

    static func asciiHost(_ components: URLComponents) -> String? {
        components.encodedHost.map { $0.lowercased() }
    }

    /// Host as shown to the user: Unicode per label only where the policy deems it safe.
    public static func displayHost(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "" }
        return displayHost(components) ?? url.host ?? ""
    }

    static func displayHost(_ components: URLComponents) -> String? {
        guard let ascii = components.encodedHost else { return components.host }
        guard ascii.lowercased().contains("xn--"), let unicode = components.host else { return ascii }
        let asciiLabels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        let unicodeLabels = unicode.split(separator: ".", omittingEmptySubsequences: false)
        guard asciiLabels.count == unicodeLabels.count else { return ascii }
        return zip(asciiLabels, unicodeLabels).map { encoded, decoded in
            guard encoded.lowercased().hasPrefix("xn--") else { return String(encoded) }
            return isSafe(label: decoded) ? String(decoded) : String(encoded)
        }.joined(separator: ".")
    }

    private enum Script: Hashable { case latin, cyrillic, greek, han, hiragana, katakana, bopomofo, hangul }

    static func isSafe<S: StringProtocol>(label: S) -> Bool {
        let scalars = Array(label.unicodeScalars)
        guard !scalars.isEmpty, scalars.contains(where: { !$0.isASCII }) else { return false }
        var scripts = Set<Script>()
        for (index, scalar) in scalars.enumerated() {
            if isASCIIDigitOrHyphen(scalar) { continue }
            guard let script = script(of: scalar) else { return false }
            scripts.insert(script)
            if !allowedInContext(scalar, previous: index > 0 ? scalars[index - 1] : nil,
                                 next: index + 1 < scalars.count ? scalars[index + 1] : nil) { return false }
        }
        guard let first = scripts.first else { return false }
        // Only Japanese (Han + kana), Chinese (Han + Bopomofo) and Korean (Han + Hangul) mix scripts.
        if scripts.count > 1, ![[.han, .hiragana, .katakana], [.han, .bopomofo], [.han, .hangul]].contains(where: scripts.isSubset(of:)) {
            return false
        }
        switch first {
        case .cyrillic: return scalars.contains { script(of: $0) == .cyrillic && !cyrillicLookalikes.contains($0) }
        case .greek: return scalars.contains { script(of: $0) == .greek && !greekLookalikes.contains($0) }
        default: return true
        }
    }

    private static func isASCIIDigitOrHyphen(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || scalar == "-"
    }

    private static func script(of scalar: Unicode.Scalar) -> Script? {
        let value = scalar.value
        if ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) { return .latin }
        switch value {
        case 0x00DF...0x00F6, 0x00F8...0x00FF: return .latin
        case 0x0100...0x017F: return latinExtendedLookalikes.contains(value) ? nil : .latin
        case 0x0218...0x021B: return .latin // Romanian comma-below letters
        case 0x03AC...0x03CE: return .greek
        case 0x0430...0x045F: return .cyrillic
        case 0x3041...0x3096, 0x309D...0x309F: return .hiragana
        case 0x30A1...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF: return .katakana
        case 0x3105...0x312F: return .bopomofo
        case 0x1100...0x11FF, 0x3131...0x318E, 0xAC00...0xD7A3: return .hangul
        case 0x3005, 0x3006, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:
            return hanLookalikes.contains(value) ? nil : .han
        default: return nil
        }
    }

    /// Dash- or slash-like kana and Han characters are only shown between East Asian letters.
    private static func allowedInContext(_ scalar: Unicode.Scalar, previous: Unicode.Scalar?, next: Unicode.Scalar?) -> Bool {
        func eastAsian(_ other: Unicode.Scalar?) -> Bool {
            guard let other, let script = script(of: other) else { return false }
            return [.han, .hiragana, .katakana, .bopomofo, .hangul].contains(script)
        }
        func kana(_ other: Unicode.Scalar?) -> Bool {
            guard let other, let script = script(of: other) else { return false }
            return script == .hiragana || script == .katakana
        }
        switch scalar.value {
        case 0x30FC: return kana(previous) // prolonged sound mark follows kana
        case 0x4E00, 0x30CE, 0x30D8, 0x3078: // 一 ノ ヘ へ
            return (previous != nil || next != nil) && (previous == nil || eastAsian(previous)) && (next == nil || eastAsian(next))
        default: return true
        }
    }

    /// ı ĸ Ŀ ŀ ŉ ſ look like ASCII letters or punctuation.
    private static let latinExtendedLookalikes: Set<UInt32> = [0x0131, 0x0138, 0x013F, 0x0140, 0x0149, 0x017F]
    /// 〇 丨 丶 丿 乀 乙 亅 look like ASCII letters, digits or punctuation.
    private static let hanLookalikes: Set<UInt32> = [0x3007, 0x4E28, 0x4E36, 0x4E3F, 0x4E40, 0x4E59, 0x4E85]
    private static let cyrillicLookalikes: Set<Unicode.Scalar> = Set("аеорсухѕіјпгьъыю".unicodeScalars)
    private static let greekLookalikes: Set<Unicode.Scalar> = Set("αβγεηικνορτυχωμς".unicodeScalars)
}
