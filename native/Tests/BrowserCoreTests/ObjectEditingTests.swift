import Foundation
import Testing
@testable import BrowserCore

struct ObjectEditingTests {
    @Test("Custom tab icons apply, reset, undo, redo and round trip without changing the title or destination")
    func icons() async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("icon")
        let selected = try await f.open("selected")
        let before = try #require(await f.organization().tab(id))
        for icon in [BrowserSpaceIcon.grapheme("😀"), .systemSymbol("heart.fill")] {
            _ = try await f.store.changeTabIcon(id, to: icon, from: f.context())
            var tab = try #require(await f.organization().tab(id))
            #expect(tab.customIcon == icon && tab.url == before.url && tab.title == before.title)
            #expect(!tab.isSelected && tab.isSelected == before.isSelected)
            #expect(try await f.organization().selectedTab?.id == selected)
            let document = await f.store.sessionDocument()
            let roundTrip = try JSONDecoder().decode(BrowserSessionDocument.self, from: JSONEncoder().encode(document))
            try roundTrip.validate()
            #expect(roundTrip.organization.tabs.first { $0.id == id }?.customIcon == icon)
            _ = try await f.store.changeTabIcon(id, to: nil, from: f.context())
            #expect(try await f.organization().tab(id)?.customIcon == nil)
            _ = try await f.store.undoOrganization(from: f.context())
            tab = try #require(await f.organization().tab(id))
            #expect(tab.customIcon == icon)
            _ = try await f.store.redoOrganization(from: f.context())
            #expect(try await f.organization().tab(id)?.customIcon == nil)
        }
        // A legacy tab has no field; decoding supplies nil.
        let data = try JSONEncoder().encode(await f.store.sessionDocument())
        #expect(!String(decoding: data, as: UTF8.self).contains("customIcon"))
        await #expect(throws: BrowserOrganizationError.invalidIcon) {
            try await f.store.changeTabIcon(id, to: .grapheme("two"), from: f.context())
        }
        try await f.validate()
    }

    @Test("Pinned URL editing is reversible and preserves away navigation until reset")
    func pinnedURL() async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("home")
        _ = try await f.store.pinTabs([id], from: f.context())
        let replacement = organizationURL("replacement")
        _ = try await f.store.editPinnedURL(id, to: replacement, from: f.context())
        var tab = try #require(await f.organization().tab(id))
        #expect(tab.pinnedURL == replacement && tab.url == organizationURL("home") && tab.isAwayFromPinnedURL)
        let doc = try JSONDecoder().decode(BrowserSessionDocument.self, from: JSONEncoder().encode(await f.store.sessionDocument()))
        try doc.validate()
        #expect(doc.organization.tabs.first { $0.id == id }?.pinnedURL == replacement)
        _ = try await f.store.undoOrganization(from: f.context())
        tab = try #require(await f.organization().tab(id))
        #expect(tab.pinnedURL == organizationURL("home") && !tab.isAwayFromPinnedURL)
        _ = try await f.store.redoOrganization(from: f.context())
        #expect(try await f.organization().tab(id)?.pinnedURL == replacement)
        let (reset, state) = try await f.store.resetTabToPinnedURL(id, from: f.context())
        #expect(reset.url == replacement && state.organization.tab(id)?.isAwayFromPinnedURL == false)
        _ = try await f.store.editPinnedURL(id, to: organizationURL("home"), from: f.context())
        _ = try await f.store.resetTabToPinnedURL(id, from: f.context())
        #expect(try await f.organization().tab(id)?.url == organizationURL("home"))
        let today = try await f.open("today")
        await #expect(throws: BrowserOrganizationError.notPinned) {
            try await f.store.editPinnedURL(today, to: replacement, from: f.context())
        }
    }

    @Test("Pinned customization syncs and reset clears the receiving icon")
    func sync() async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("home")
        _ = try await f.store.pinTabs([id], from: f.context())
        let local = await f.store.sessionDocument()
        var replica = BrowserSyncReplica(device: "synthetic")
        func project(_ doc: BrowserSessionDocument) throws -> BrowserSyncProjection {
            try BrowserSyncMapping.project(session: doc, settings: .init())
        }
        try replica.capture(project(local), now: Date(timeIntervalSince1970: 100))
        _ = try await f.store.changeTabIcon(id, to: .grapheme("😀"), from: f.context())
        _ = try await f.store.editPinnedURL(id, to: organizationURL("replacement"), from: f.context())
        try replica.capture(project(await f.store.sessionDocument()), now: Date(timeIntervalSince1970: 101))
        let materialized = try BrowserSyncMapping.materialize(replica.visible, local: local, settings: .init())
        let tab = try #require(materialized.organization.tabs.first { $0.id == id })
        #expect(tab.customIcon == .grapheme("😀") && tab.pinnedURL == organizationURL("replacement"))
        #expect(tab.url == organizationURL("replacement"))
        _ = try await f.store.changeTabIcon(id, to: nil, from: f.context())
        try replica.capture(project(await f.store.sessionDocument()), now: Date(timeIntervalSince1970: 102))
        let reset = try BrowserSyncMapping.materialize(replica.visible, local: local, settings: .init())
        #expect(reset.organization.tabs.first { $0.id == id }?.customIcon == nil)
    }

    @Test("Independent fields survive undo and another window's edit prevents overwriting its icon")
    func conflict() async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("home")
        _ = try await f.store.pinTabs([id], from: f.context())
        _ = try await f.store.changeTabIcon(id, to: .grapheme("😀"), from: f.context())
        _ = try await f.store.renameTab(id, to: "Other title", from: f.context(f.other))
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(try await f.organization().tab(id)?.customTitle == "Other title")
        #expect(try await f.organization().tab(id)?.customIcon == nil)
        _ = try await f.store.changeTabIcon(id, to: .grapheme("😀"), from: f.context())
        _ = try await f.store.changeTabIcon(id, to: .grapheme("😃"), from: f.context(f.other))
        #expect(try await f.organization().undoAction != .changeTabIcon)
        try await f.validate()
    }
}
