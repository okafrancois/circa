import BrowserCore
import Foundation
import Testing
@testable import BrowserShell

@MainActor
private final class BookmarkSessionSurface: BrowserSurface {
    var currentURL: URL? { nil }
    func dispose() {}
}

@Suite("Bookmark session FIFO and admission", .serialized)
@MainActor
struct BrowserBookmarkSessionTests {
    private var document: BrowserBookmarkDocument {
        .init(entries: [.folder(title: "Nested", children: [
            .link(title: "Synthetic saved link", url: URL(string: "https://session-bookmark.test/")!)
        ])])
    }
    private func fixture() async throws -> (BrowserStore, BrowserWindowSession<BookmarkSessionSurface>, SpaceID) {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic bookmark session")
        let space = try await store.createSpace(name: "Source", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let session = BrowserWindowSession(store: store, restoringWindowID: window) { _, _ in
            Issue.record("Dormant bookmark commands must not request a surface")
            return BookmarkSessionSurface()
        }
        session.onError = { _ in }
        await session.waitForPendingCommands()
        return (store, session, space)
    }

    @Test("One token cannot replay its commit; export observes preceding imports and folder commands in FIFO")
    func oneCommitAndFIFO() async throws {
        let (store, session, space) = try await fixture()
        defer { session.close() }
        let expected = try #require(session.paletteContext)
        let admission = BrowserBookmarkImportAdmission()
        _ = session.createFolder(title: "Earlier", at: .init(.pinned(space)))
        let first = session.importBookmarks(document, title: "Imported", from: expected, admission: admission)
        let duplicate = session.importBookmarks(document, title: "Duplicate", from: expected, admission: admission)
        let exported = session.exportBookmarks(from: expected)
        #expect(await first.value != nil)
        #expect(await duplicate.value == nil)
        let result = try #require(await exported.value)
        #expect(result.entries == [.folder(title: "Source", children: [
            .folder(title: "Earlier", children: []), .folder(title: "Imported", children: document.entries)
        ])])
        #expect(admission.state == .admitted && !admission.revoke())
        #expect((await store.sessionDocument()).organization.tabs.count == 1)
        await session.waitForPendingCommands()
        #expect(!session.hasPendingCommands)
    }

    @Test("Pre-revoked admission and a queued source change cannot commit or retarget")
    func revokedAndPendingChange() async throws {
        let (store, session, _) = try await fixture()
        defer { session.close() }
        let expected = try #require(session.paletteContext)
        let revoked = BrowserBookmarkImportAdmission()
        revoked.revoke()
        #expect(await session.importBookmarks(document, title: "Revoked", from: expected, admission: revoked).value == nil)
        let profile = await store.createProfile(name: "Synthetic foreign session")
        let alternate = try await store.createSpace(name: "Foreign", profileID: profile)
        session.activateSpace(alternate)
        let gate = BrowserBookmarkImportAdmission()
        let stale = session.importBookmarks(document, title: "Stale", from: expected, admission: gate)
        let staleExport = session.exportBookmarks(from: expected)
        #expect(await stale.value == nil && gate.state == .revoked)
        #expect(await staleExport.value == nil)
        #expect((await store.sessionDocument()).organization.tabs.isEmpty)
        #expect(session.activeProfileID == profile)
    }

    @Test("Source closure or termination revokes every pending session admission", arguments: [false, true])
    func retirement(termination: Bool) async throws {
        let (store, session, _) = try await fixture()
        let expected = try #require(session.paletteContext)
        let first = BrowserBookmarkImportAdmission(), second = BrowserBookmarkImportAdmission()
        let one = session.importBookmarks(document, title: "One", from: expected, admission: first)
        let two = session.importBookmarks(document, title: "Two", from: expected, admission: second)
        if termination { session.retireForApplicationTermination() } else { session.close() }
        #expect(first.state == .revoked && second.state == .revoked)
        let oneResult = await one.value
        let twoResult = await two.value
        #expect(oneResult == nil && twoResult == nil)
        await session.waitForPendingCommands()
        #expect(session.bookmarkAdmissions.isEmpty && !session.hasPendingCommands)
        #expect((await store.sessionDocument()).organization.tabs.isEmpty)
    }

    @Test("Actor refusal remains a failure without mutation and does not reuse an admitted token")
    func invalidAtomicRefusal() async throws {
        let (store, session, _) = try await fixture()
        defer { session.close() }
        let expected = try #require(session.paletteContext)
        let invalid = BrowserBookmarkDocument(entries: [.link(title: "Refused", url: URL(string: "file:///synthetic")!)])
        let gate = BrowserBookmarkImportAdmission()
        let before = await store.sessionDocument()
        #expect(await session.importBookmarks(invalid, title: "Invalid", from: expected, admission: gate).value == nil)
        #expect(gate.state == .admitted)
        #expect(await store.sessionDocument() == before)
        #expect(await session.importBookmarks(document, title: "Replayed", from: expected, admission: gate).value == nil)
        #expect(await store.sessionDocument() == before)
    }
}
