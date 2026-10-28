import Foundation
import Testing
@testable import BrowserCore

@Suite("Sidebar rows, multi-selection and drop validation")
struct BrowserOrganizationSelectionTests {
    private struct Layout {
        let fixture: OrganizationFixture
        let favorite: TabID
        let folder: FolderID
        let inFolder: TabID
        let pinned: TabID
        let today: [TabID]
    }

    /// Favorites [favorite]; Pinned [folder [inFolder], pinned]; Today [t2, t1, t0].
    private func layout() async throws -> Layout {
        let fixture = try await OrganizationFixture.make()
        let favorite = try await fixture.open("favorite")
        let inFolder = try await fixture.open("in-folder")
        let pinned = try await fixture.open("pinned")
        var today: [TabID] = []
        for index in 0..<3 { today.insert(try await fixture.open("t\(index)"), at: 0) }
        _ = try await fixture.store.addToFavorites([favorite], from: fixture.context())
        let (folder, _) = try await fixture.store.createFolder(title: "Folder", at: .init(.pinned(fixture.home)),
            containing: [.tab(inFolder)], from: fixture.context())
        _ = try await fixture.store.pinTabs([pinned], from: fixture.context())
        return Layout(fixture: fixture, favorite: favorite, folder: folder, inFolder: inFolder, pinned: pinned, today: today)
    }

    @Test("Rows follow display order with depth and groups")
    func rowsOrder() async throws {
        let layout = try await layout()
        let snapshot = try await layout.fixture.organization()
        let rows = snapshot.rows()
        #expect(rows.map(\.node) == [.tab(layout.favorite), .folder(layout.folder), .tab(layout.inFolder),
                                     .tab(layout.pinned)] + layout.today.map { .tab($0) })
        #expect(rows.map(\.group) == [.favorites] + Array(repeating: .list, count: 6))
        #expect(rows[2].depth == 1 && rows[2].parentFolderID == layout.folder)
        #expect(snapshot.selectedTab?.id == layout.today[0])
        #expect(snapshot.allTabs.count == 6)
    }

    @Test("Command-click toggles, shift-click selects a range within one group, and selection stays in context")
    func multiSelection() async throws {
        let layout = try await layout()
        let snapshot = try await layout.fixture.organization()
        var selection = BrowserOrganizationSelection()
        selection.select(.tab(layout.pinned), in: snapshot)
        selection.extend(to: .tab(layout.today[1]), in: snapshot)
        #expect(selection.orderedNodes(in: snapshot) == [.tab(layout.pinned), .tab(layout.today[0]), .tab(layout.today[1])])
        selection.toggle(.tab(layout.today[0]), in: snapshot)
        #expect(selection.orderedNodes(in: snapshot) == [.tab(layout.pinned), .tab(layout.today[1])])
        #expect(selection.anchor == .tab(layout.today[0]))
        selection.toggle(.tab(layout.inFolder), in: snapshot)
        selection.extend(to: .tab(layout.favorite), in: snapshot)
        // A range never crosses from the list into the Favorites grid.
        #expect(selection.orderedNodes(in: snapshot) == [.tab(layout.favorite)])
        selection.select(.folder(layout.folder), in: snapshot)
        selection.extend(to: .tab(layout.today[2]), in: snapshot)
        #expect(selection.nodes.count == 6)

        _ = try await layout.fixture.store.archiveTabs([layout.today[2]], from: layout.fixture.context())
        _ = try await layout.fixture.store.setFolderCollapsed(layout.folder, true, from: layout.fixture.context())
        let changed = try await layout.fixture.organization()
        selection.reconcile(with: changed)
        #expect(selection.orderedNodes(in: changed) == [.folder(layout.folder), .tab(layout.pinned),
                                                        .tab(layout.today[0]), .tab(layout.today[1])])
        try await layout.fixture.activate(layout.fixture.leisure)
        let leisure = try await layout.fixture.organization()
        #expect(selection.orderedNodes(in: leisure).isEmpty)
        selection.reconcile(with: leisure)
        #expect(selection.isEmpty && selection.anchor == nil)
        selection.select(.tab(layout.pinned), in: leisure)
        #expect(selection.isEmpty)
    }

    @Test("Drop validation matches the store's decisions")
    func dropValidation() async throws {
        let layout = try await layout()
        let fixture = layout.fixture
        let snapshot = try await fixture.organization()
        let catalog = await fixture.store.catalogSnapshot()
        let cases: [([BrowserOrganizationNode], BrowserOrganizationDestination, BrowserOrganizationError?)] = [
            ([.tab(layout.today[0])], .init(.folder(layout.folder), position: .before(.tab(layout.inFolder))), nil),
            ([.tab(layout.pinned)], .init(.favorites(fixture.personal)), nil),
            ([.tab(layout.pinned)], .init(.today(fixture.leisure)), nil),
            ([.folder(layout.folder)], .init(.today(fixture.home)), .invalidDestination),
            ([.folder(layout.folder)], .init(.favorites(fixture.personal)), .invalidDestination),
            ([.folder(layout.folder)], .init(.folder(layout.folder)), .cycle),
            ([.tab(layout.pinned)], .init(.today(fixture.lab)), .crossProfileMove),
            ([.tab(layout.pinned)], .init(.favorites(fixture.work)), .crossProfileMove),
            ([.tab(layout.pinned)], .init(.today(fixture.home), position: .before(.tab(layout.inFolder))), .invalidPosition),
            ([.tab(TabID())], .init(.today(fixture.home)), .notVisibleInContext),
            ([], .init(.today(fixture.home)), .emptySelection)
        ]
        for (nodes, destination, expected) in cases {
            #expect(snapshot.validateMove(nodes, to: destination, catalog: catalog) == expected)
            do {
                _ = try await fixture.store.moveItems(nodes, to: destination, from: fixture.context())
                #expect(expected == nil)
                _ = try await fixture.store.undoOrganization(from: fixture.context())
            } catch let error as BrowserOrganizationError {
                #expect(expected == error || (expected == .notVisibleInContext && error == .itemMissing))
            }
        }
        try await fixture.validate()
    }
}
