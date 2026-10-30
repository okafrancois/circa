import Foundation
import Testing
@testable import BrowserCore

struct LocalFilesImportTests {
    @Test("Foreign session imports never create native document consent")
    func importedSession() async throws {
        let file = URL(fileURLWithPath: "/tmp/synthetic-imported.pdf")
        let profile = ArcProfileKey.directory("Default")
        let source = ArcImportedTab(sourceID: "synthetic", savedURL: file, savedTitle: "Synthetic",
            customTitle: nil, createdAt: nil, lastActiveAt: nil)
        let graph = ArcSidebarGraph(formatVersion: 1, formatRecognized: true, profiles: [],
            spaces: [.init(sourceID: "synthetic-space", profile: profile, title: "Synthetic",
                appearance: .init(), pinned: [.tab(source)], today: [source])],
            favorites: [], archive: [], diagnostics: .init())
        let plan = ArcImportMapper.plan(graph, defaultProfileTarget: ProfileID(), importedAt: Date())
        for section in plan.sections {
            #expect(section.today.allSatisfy { $0.localDocument == nil })
            for node in section.pinned {
                if case let .tab(tab) = node { #expect(tab.localDocument == nil) }
            }
        }
    }

}
