import Foundation
import Testing
@testable import BrowserCore

@Suite("Today suggestions and confirmed mutations")
struct BrowserAITodaySuggestionTests {
    private func response(_ rows: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["suggestions": rows]), as: UTF8.self)
    }

    @Test func groupsAcceptOnlyKnownUniqueTabIdentities() throws {
        let a = TabID(), b = TabID(), c = TabID()
        let rows: [[String: Any]] = [
            ["action": "folder", "title": "Project", "tabs": [a.rawValue.uuidString, b.rawValue.uuidString]],
            ["action": "archive", "title": "Finished", "tabs": [c.rawValue.uuidString]]
        ]
        let groups = try BrowserAITodaySuggestion.parse(response(rows), allowed: [a, b, c])
        #expect(groups.count == 2 && groups[0].tabs == [a, b] && groups[1].action == .archive)
        #expect(try BrowserAITodaySuggestion.parse(response([]), allowed: [a, b]).isEmpty)
        #expect(throws: (any Error).self) {
            try BrowserAITodaySuggestion.parse("{\"suggestions\":[],\"command\":\"run\"}", allowed: [a, b])
        }
        for invalid in [
            [["action": "archive", "title": "One", "tabs": [a.rawValue.uuidString], "command": "run"]],
            [["action": "folder", "title": "Project", "tabs": [a.rawValue.uuidString, c.rawValue.uuidString]]],
            [["action": "folder", "title": "Project", "tabs": [a.rawValue.uuidString, a.rawValue.uuidString]]],
            [["action": "archive", "title": "One", "tabs": [a.rawValue.uuidString]],
             ["action": "archive", "title": "Two", "tabs": [a.rawValue.uuidString]]],
            [["action": "execute", "title": "Command", "tabs": [a.rawValue.uuidString]]],
            [["action": "folder", "title": "One", "tabs": [a.rawValue.uuidString]]]
        ] {
            #expect(throws: (any Error).self) { try BrowserAITodaySuggestion.parse(response(invalid), allowed: [a, b]) }
        }
    }

    @Test func confirmingFolderIsAtomicAndUndoable() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("alpha"), b = try await f.open("beta")
        let initial = try await f.organization()
        let proposal = BrowserAITodaySuggestion(action: .folder, title: "Research", tabs: [a, b])
        _ = try await f.store.applyTodaySuggestion(proposal, revision: initial.organizationRevision, from: f.context())
        let grouped = try await f.store.sessionDocument().organization
        #expect(grouped.folders.count == 1)
        #expect(try await f.organization().allTabs.filter { if case .pinned = $0.section { return true }; return false }.count == 2)
        _ = try await f.store.undoOrganization(from: f.context())
        let restored = try await f.organization()
        #expect(restored.allTabs.filter { if case .today = $0.section { return true }; return false }.map(\.id) == initial.allTabs.map(\.id))
        #expect(await f.store.sessionDocument().organization.folders.isEmpty)
    }

    @Test func staleOrPinnedCandidatesCannotCreatePartialFoldersOrArchiveTabs() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("alpha"), b = try await f.open("beta")
        let initial = try await f.organization()
        _ = try await f.store.renameTab(a, to: "Manual", from: f.context())
        await #expect(throws: BrowserStoreError.staleContext) {
            try await f.store.applyTodaySuggestion(.init(action: .folder, title: "Late", tabs: [a, b]),
                                                   revision: initial.organizationRevision, from: f.context())
        }
        #expect(await f.store.sessionDocument().organization.folders.isEmpty)
        _ = try await f.store.pinTabs([a], from: f.context())
        let current = try await f.organization()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await f.store.applyTodaySuggestion(.init(action: .archive, title: "No", tabs: [a, b]),
                                                   revision: current.organizationRevision, from: f.context())
        }
        #expect(try await f.organization().allTabs.count == 2)
    }
}
