import AppKit
import BrowserCore

struct SpaceIconPickerCatalog: Sendable {
    enum Category: Int, CaseIterable, Sendable {
        case smileys, people, animals, food, activities, travel, objects, symbols, flags

        var title: String {
            switch self {
            case .smileys: uiText("Smileys & Emotion")
            case .people: uiText("People & Body")
            case .animals: uiText("Animals & Nature")
            case .food: uiText("Food & Drink")
            case .activities: uiText("Activities")
            case .travel: uiText("Travel & Places")
            case .objects: uiText("Objects")
            case .symbols: uiText("Symbols")
            case .flags: uiText("Flags")
            }
        }

        /// SF Symbol of the category bar.
        var symbol: String {
            switch self {
            case .smileys: "face.smiling"
            case .people: "hand.wave"
            case .animals: "leaf"
            case .food: "fork.knife"
            case .activities: "soccerball"
            case .travel: "car"
            case .objects: "lightbulb"
            case .symbols: "heart"
            case .flags: "flag"
            }
        }
    }

    struct Item: Equatable, Sendable {
        let choice: BrowserSpaceIcon
        var emoji: String { if case .grapheme(let value) = choice { value } else { "" } }
        /// Lowercased English Unicode name, used for search and accessibility.
        let name: String
        let category: Category
        init(emoji: String, name: String, category: Category) {
            choice = .grapheme(emoji); self.name = name; self.category = category
        }
        init(symbol: String, name: String) {
            choice = .systemSymbol(symbol); self.name = name; category = .symbols
        }
    }

    static let shared = SpaceIconPickerCatalog()

    let items: [Item]

    init() {
        var items: [Item] = []
        var seen = Set<String>()
        for range in Self.scalarRanges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), Self.isListed(scalar) else { continue }
                let emoji = scalar.properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                guard seen.insert(emoji).inserted else { continue }
                let name = (scalar.properties.name ?? "").lowercased()
                items.append(Item(emoji: emoji, name: name, category: Self.category(of: value)))
            }
        }
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            let letters = region.identifier.uppercased().unicodeScalars
            guard letters.allSatisfy({ ("A"..."Z").contains(Character($0)) }) else { continue }
            let flag = String(String.UnicodeScalarView(letters.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }))
            guard seen.insert(flag).inserted else { continue }
            let country = Locale(identifier: "en").localizedString(forRegionCode: region.identifier) ?? region.identifier
            items.append(Item(emoji: flag, name: "flag " + country.lowercased(), category: .flags))
        }
        // Stable order: category, then code point order within it.
        self.items = Self.Category.allCases.flatMap { category in items.filter { $0.category == category } }
    }

    func items(in category: Category) -> [Item] { items.filter { $0.category == category } }

    /// Every word of the query must prefix a word of the name ("red hea" → red heart).
    func search(_ query: String) -> [Item] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let nameWords = item.name.split(whereSeparator: { $0 == " " || $0 == "-" })
            return words.allSatisfy { word in nameWords.contains { $0.hasPrefix(word) } }
        }
    }

    /// The typed text, when it is exactly one emoji grapheme the settings accept.
    static func typedEmoji(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let first = trimmed.unicodeScalars.first,
              first.properties.isEmoji, first.value > 0x7F || trimmed.unicodeScalars.count > 1 else { return nil }
        return trimmed
    }

    private static let scalarRanges: [ClosedRange<UInt32>] = [
        0x00A9...0x00AE, 0x203C...0x2049, 0x2122...0x2139, 0x2194...0x21AA, 0x231A...0x23FF,
        0x24C2...0x24C2, 0x25AA...0x25FE, 0x2600...0x27BF, 0x2934...0x2935, 0x2B05...0x2B55,
        0x3030...0x303D, 0x3297...0x3299, 0x1F004...0x1F251, 0x1F300...0x1FAFF
    ]

    private static func isListed(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        guard scalar.properties.isEmoji else { return false }
        if (0x1F1E6...0x1F1FF).contains(value) { return false }   // regional indicators (flags are pairs)
        if (0x1F3FB...0x1F3FF).contains(value) { return false }   // skin-tone modifiers
        if (0x1F9B0...0x1F9B3).contains(value) { return false }   // hair components
        return true
    }

    private static func category(of value: UInt32) -> Category {
        func any(_ ranges: [ClosedRange<UInt32>]) -> Bool { ranges.contains { $0.contains(value) } }
        if any([0x1F600...0x1F637, 0x1F641...0x1F644, 0x1F910...0x1F915, 0x1F917...0x1F917, 0x1F920...0x1F92F,
                0x1F970...0x1F97A, 0x1FAE0...0x1FAEF, 0x2639...0x263A, 0x1F48B...0x1F49F, 0x2763...0x2764,
                0x1F4A2...0x1F4AB, 0x1F638...0x1F640, 0x1F648...0x1F64A, 0x1F5E8...0x1F5E8, 0x1F5EF...0x1F5EF,
                0x1F573...0x1F573, 0x1F90D...0x1F90E, 0x1F9E1...0x1F9E1, 0x1FA75...0x1FA77, 0x1F5A4...0x1F5A4]) {
            return .smileys
        }
        if any([0x1F440...0x1F450, 0x1F466...0x1F487, 0x1F645...0x1F647, 0x1F64B...0x1F64F, 0x1F90C...0x1F90C,
                0x1F90F...0x1F90F, 0x1F918...0x1F91F, 0x1F926...0x1F926, 0x1F930...0x1F93A, 0x1F9B5...0x1F9BB,
                0x1F9CD...0x1F9DF, 0x1FAC0...0x1FAC5, 0x1FAF0...0x1FAFF, 0x270A...0x270D, 0x1F574...0x1F57A,
                0x1F590...0x1F596, 0x261D...0x261D, 0x1F4AA...0x1F4AA, 0x1F463...0x1F465, 0x1F9E0...0x1F9E0]) {
            return .people
        }
        if any([0x1F400...0x1F43F, 0x1F330...0x1F344, 0x1F980...0x1F9AE, 0x1FAB0...0x1FABF, 0x1F490...0x1F490,
                0x1F300...0x1F320, 0x2600...0x2604, 0x2614...0x2614, 0x2618...0x2618, 0x26A1...0x26A1,
                0x2744...0x2744, 0x1F4AE...0x1F4AE, 0x1F940...0x1F940, 0x1F54A...0x1F54A, 0x1F577...0x1F578,
                0x1F525...0x1F525, 0x1F4A7...0x1F4A7, 0x1F32D...0x1F32F]) {
            return .animals
        }
        if any([0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x1FAD0...0x1FADF, 0x2615...0x2615]) {
            return .food
        }
        if any([0x1F380...0x1F393, 0x1F396...0x1F3CF, 0x1F93C...0x1F94F, 0x26BD...0x26BE, 0x26F3...0x26F3,
                0x26F8...0x26F8, 0x1FA80...0x1FA8F, 0x1F0CF...0x1F0CF, 0x1F004...0x1F004, 0x265F...0x265F,
                0x1F9E9...0x1F9E9, 0x1F9F5...0x1F9F6, 0x1F3AE...0x1F3AE]) {
            return .activities
        }
        if any([0x1F680...0x1F6FF, 0x1F3D4...0x1F3F0, 0x1F5FA...0x1F5FF, 0x26F0...0x26FD, 0x2708...0x2708,
                0x1F321...0x1F32C, 0x1F30D...0x1F31F, 0x231A...0x231B, 0x23F0...0x23F3, 0x1F550...0x1F567,
                0x1F9F3...0x1F9F3, 0x1F6E0...0x1F6E0]) {
            if value == 0x1F6A9 { return .flags }
            return (0x1F6B9...0x1F6BC).contains(value) || (0x1F6AE...0x1F6B7).contains(value) ? .symbols : .travel
        }
        if any([0x1F3C1...0x1F3C1, 0x1F38C...0x1F38C, 0x1F3F3...0x1F3F4]) { return .flags }
        if any([0x1F4A0...0x1F4FF, 0x1F500...0x1F53D, 0x1F56F...0x1F5F9, 0x1FA70...0x1FAAF, 0x2328...0x2328,
                0x260E...0x260E, 0x2702...0x2702, 0x2709...0x2709, 0x270F...0x2712, 0x1F9EA...0x1F9FF,
                0x23E9...0x23EF, 0x1F3A5...0x1F3AD, 0x1F3B7...0x1F3BB, 0x26CF...0x26CF, 0x2692...0x2697,
                0x2699...0x269C, 0x26B0...0x26B1, 0x1F9AF...0x1F9AF, 0x1F9BC...0x1F9BD]) {
            return .objects
        }
        return .symbols
    }
}

@MainActor
enum SpaceSymbolCatalog {
    static let definitions: [(identifier: String, title: String)] = [
        ("globe", "Globe"), ("house.fill", "Home"), ("briefcase.fill", "Work"),
        ("person.fill", "Person"), ("person.2.fill", "People"), ("heart.fill", "Heart"),
        ("star.fill", "Star"), ("bookmark.fill", "Bookmark"), ("flag.fill", "Flag"),
        ("folder.fill", "Folder"), ("tray.fill", "Inbox"), ("books.vertical.fill", "Books"),
        ("graduationcap.fill", "Study"), ("pencil", "Pencil"), ("paintpalette.fill", "Art"),
        ("camera.fill", "Camera"), ("photo.fill", "Photo"), ("music.note", "Music"),
        ("headphones", "Headphones"), ("gamecontroller.fill", "Games"), ("film.fill", "Film"),
        ("leaf.fill", "Leaf"), ("tree.fill", "Tree"), ("sun.max.fill", "Sun"),
        ("moon.fill", "Moon"), ("cloud.fill", "Cloud"), ("bolt.fill", "Lightning"),
        ("flame.fill", "Fire"), ("drop.fill", "Water"), ("mountain.2.fill", "Mountains"),
        ("airplane", "Travel"), ("car.fill", "Car"), ("bicycle", "Bicycle"),
        ("sailboat.fill", "Sailing"), ("map.fill", "Map"), ("location.fill", "Location"),
        ("cup.and.saucer.fill", "Coffee"), ("fork.knife", "Food"), ("cart.fill", "Shopping"),
        ("gift.fill", "Gift"), ("bag.fill", "Bag"), ("creditcard.fill", "Finance"),
        ("hammer.fill", "Tools"), ("wrench.fill", "Wrench"), ("gearshape.fill", "Settings"),
        ("terminal.fill", "Terminal"), ("curlybraces", "Code"), ("desktopcomputer", "Computer"),
        ("lightbulb.fill", "Ideas"), ("magnifyingglass", "Research"), ("puzzlepiece.fill", "Puzzle"),
        ("sportscourt.fill", "Sport"), ("trophy.fill", "Trophy"), ("medal.fill", "Medal"),
        ("lock.fill", "Lock"), ("key.fill", "Key"), ("shield.fill", "Shield"),
        ("bell.fill", "Bell"), ("calendar", "Calendar"), ("clock.fill", "Clock"),
        ("checkmark.seal.fill", "Checkmark"), ("paperplane.fill", "Send"), ("envelope.fill", "Mail"),
        ("bubble.left.fill", "Chat")
    ]

    static let items: [SpaceIconPickerCatalog.Item] = definitions.compactMap {
        guard SpaceIconImages.template($0.identifier, pointSize: 20) != nil else { return nil }
        return .init(symbol: $0.identifier, name: uiText($0.title))
    }

    static func contains(_ choice: BrowserSpaceIcon) -> Bool { items.contains { $0.choice == choice } }

    static func search(_ query: String) -> [SpaceIconPickerCatalog.Item] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        return items.filter { item in
            guard case .systemSymbol(let identifier) = item.choice else { return false }
            let english = definitions.first { $0.identifier == identifier }?.title ?? ""
            let names = (item.name + " " + english + " " + identifier)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: { $0.isWhitespace || $0 == "." })
            return words.allSatisfy { word in names.contains { $0.hasPrefix(word) } }
        }
    }

    static func title(for identifier: String) -> String {
        definitions.first { $0.identifier == identifier }.map { uiText($0.title) } ?? uiText("Icon")
    }
}
