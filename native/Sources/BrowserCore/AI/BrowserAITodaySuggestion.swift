import Foundation

/// Model-proposed organization is data. Only explicitly supplied tab identities can be acted on.
public struct BrowserAITodaySuggestion: Equatable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable { case folder, archive }
    public let id: UUID
    public let action: Action
    public let title: String
    public let tabs: [TabID]

    public init(action: Action, title: String, tabs: [TabID]) {
        id = UUID(); self.action = action; self.title = title; self.tabs = tabs
    }

    public static func parse(_ text: String, allowed: Set<TabID>) throws -> [Self] {
        struct Row: Decodable { let action: Action; let title: String; let tabs: [UUID] }
        struct Response: Decodable { let suggestions: [Row] }
        guard text.utf8.count <= 16_384, allowed.count <= 40 else { throw BrowserAIError.failed }
        let rows = try JSONDecoder().decode(Response.self, from: Data(text.utf8)).suggestions
        guard rows.count <= 12 else { throw BrowserAIError.failed }
        var seen: Set<TabID> = []
        return try rows.map { row in
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = row.tabs.map { TabID($0) }
            guard !title.isEmpty, title.count <= 80, title.utf8.count <= 320,
                  title.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !ids.isEmpty, ids.count <= 40, row.action != .folder || ids.count >= 2,
                  Set(ids).count == ids.count, Set(ids).isSubset(of: allowed),
                  Set(ids).isDisjoint(with: seen) else { throw BrowserAIError.failed }
            seen.formUnion(ids)
            return Self(action: row.action, title: title, tabs: ids)
        }
    }
}
