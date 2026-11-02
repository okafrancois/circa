import Foundation

public enum BrowserAISkillScope: String, Codable, CaseIterable, Sendable {
    case thisTab, selectedTabs, selection
}

public enum BrowserAISkillError: Error, Equatable, Sendable {
    case invalidContent, limitExceeded, wrongProfile, unsupportedVersion, staleRevision
}

/// Reusable instructions only. Captured page content and conversation history are never stored here.
public struct BrowserAISkill: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var prompt: String
    public var scope: BrowserAISkillScope

    public init(id: UUID = UUID(), name: String, prompt: String, scope: BrowserAISkillScope = .thisTab) throws {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope
        try validate()
    }

    public func validate() throws {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty, prompt == prompt.trimmingCharacters(in: .whitespacesAndNewlines),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              prompt.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }) else {
            throw BrowserAISkillError.invalidContent
        }
        guard name.count <= 80, name.utf8.count <= 320,
              prompt.count <= 8_000, prompt.utf8.count <= 16_000 else { throw BrowserAISkillError.limitExceeded }
    }
}

public struct BrowserAISkillDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let profileID: ProfileID
    public internal(set) var revision: UInt64
    public internal(set) var skills: [BrowserAISkill]
    public init(profileID: ProfileID) {
        version = 1; self.profileID = profileID; revision = 1; skills = []
    }
    public func validate() throws {
        guard version == 1 else { throw BrowserAISkillError.unsupportedVersion }
        guard revision > 0, Set(skills.map(\.id)).count == skills.count else { throw BrowserAISkillError.invalidContent }
        guard skills.count <= 128 else { throw BrowserAISkillError.limitExceeded }
        try skills.forEach { try $0.validate() }
    }
}

/// Profile-owned atomic persistence. Memory-only instances never read regular-profile files.
public actor BrowserAISkillStore {
    public enum Persistence: Sendable { case memoryOnly, profileDirectory(URL) }
    public static let maximumBytes = 1_048_576
    public nonisolated let profileID: ProfileID
    private let destination: URL?
    private var document: BrowserAISkillDocument

    public init(profileID: ProfileID, persistence: Persistence = .memoryOnly) throws {
        self.profileID = profileID
        switch persistence {
        case .memoryOnly: destination = nil
        case .profileDirectory(let root):
            destination = root.appendingPathComponent(profileID.rawValue.uuidString, isDirectory: true).appendingPathComponent("skills.json")
        }
        if let destination, let bytes = try BrowserPermissionFile.load(destination, maximumBytes: Self.maximumBytes) {
            document = try JSONDecoder().decode(BrowserAISkillDocument.self, from: bytes)
        } else { document = .init(profileID: profileID) }
        guard document.profileID == profileID else { throw BrowserAISkillError.wrongProfile }
        try document.validate()
    }

    public func snapshot() -> BrowserAISkillDocument { document }

    public func save(_ skill: BrowserAISkill, expected: BrowserAISkillDocument) throws {
        guard document == expected else { throw BrowserAISkillError.staleRevision }
        try skill.validate()
        var next = document
        if let index = next.skills.firstIndex(where: { $0.id == skill.id }) { next.skills[index] = skill }
        else { next.skills.append(skill) }
        try publish(next)
    }

    public func remove(_ id: UUID, expected: BrowserAISkillDocument) throws {
        guard document == expected, document.skills.contains(where: { $0.id == id }) else { throw BrowserAISkillError.staleRevision }
        var next = document; next.skills.removeAll { $0.id == id }; try publish(next)
    }

    public func removeAll() throws {
        var next = document; next.skills = []; try publish(next)
    }

    public func applySync(_ value: BrowserAISkillDocument, expected: BrowserAISkillDocument) throws {
        guard document == expected else { throw BrowserSyncError.localChange }
        guard value.profileID == profileID else { throw BrowserAISkillError.wrongProfile }
        try value.validate()
        var next = document; next.skills = value.skills
        if next.skills != document.skills { try publish(next) }
    }

    private func publish(_ value: BrowserAISkillDocument) throws {
        guard document.revision < UInt64.max else { throw BrowserAISkillError.staleRevision }
        var next = value; next.revision = document.revision + 1
        try next.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= Self.maximumBytes else { throw BrowserAISkillError.limitExceeded }
        if let destination {
            do { try BrowserPermissionFile.save(data, to: destination, maximumBytes: Self.maximumBytes) }
            catch BrowserPermissionFile.Failure.committedButNotDurable {
                document = next; throw BrowserPermissionFile.Failure.committedButNotDurable
            }
        }
        document = next
    }
}
