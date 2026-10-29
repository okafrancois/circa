import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite("Boost rename")
@MainActor
struct BrowserBoostRenameTests {
    @Test func acceptedRenamePersistsAlongsideQueuedEdits() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/boost-rename-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), store = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Original")
        let id = session.boost.id, scope = session.boost.hostPattern
        var commits = 0
        session.onCommit = { commits += 1 }
        session.edit { $0.customCSS = "p { color: green }" }
        let sheet = BrowserBoostRenameView(name: session.boost.title) { if let name = $0 { session.rename(to: name) } }
        sheet.nameField.stringValue = "Café renamed"
        sheet.finish(true); sheet.finish(false)
        session.edit { $0.fontFamily = "Courier" }
        await session.pending?.value
        let reopened = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        let saved = try #require(await reopened.snapshot().boosts.first)
        #expect(saved.title == "Café renamed" && saved.id == id && saved.hostPattern == scope)
        #expect(saved.content.customCSS == "p { color: green }" && saved.content.fontFamily == "Courier")
        #expect(commits == 3 && session.error == nil)
        session.close(); session.rename(to: "Ignored")
        await session.pending?.value
        #expect(await store.snapshot().boosts.first?.title == "Café renamed")
    }

    @Test func cancelAndEmptyInputNeverWrite() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Original")
        let before = await store.snapshot()
        var completions = 0
        let sheet = BrowserBoostRenameView(name: session.boost.title) {
            completions += 1
            if let name = $0 { session.rename(to: name) }
        }
        #expect(sheet.nameField.stringValue == "Original")
        #expect(sheet.done.keyEquivalent == "\r" && sheet.cancel.keyEquivalent == "\u{1b}")
        for empty in ["", " ", "\n\t ", "\u{00a0}"] {
            session.rename(to: empty)
            sheet.nameField.stringValue = empty
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            #expect(!sheet.done.isEnabled)
            sheet.finish(true)
            #expect(!sheet.isFinishing && completions == 0)
        }
        sheet.nameField.stringValue = "Discarded"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(sheet.done.isEnabled)
        #expect(sheet.control(sheet.nameField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        sheet.finish(true)
        await session.pending?.value
        #expect(completions == 1 && session.pending == nil)
        #expect(await store.snapshot() == before)
    }

    @Test func renameMenuDispatchesAndReturnCommitsOnce() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Original")
        let editor = BrowserBoostEditorView(session: session, firstRun: false)
        var opened = 0
        editor.onRename = { opened += 1 }
        let menu = editor.makeHeaderMenu(), item = try #require(editor.makeHeaderMenu().items.first)
        #expect(menu.items.first?.title == "Rename this Boost…")
        #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(opened == 1)
        let sheet = BrowserBoostRenameView(name: session.boost.title) { if let name = $0 { session.rename(to: name) } }
        sheet.nameField.stringValue = "New name"
        #expect(sheet.control(sheet.nameField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        sheet.finish(true)
        await session.pending?.value
        #expect(session.boost.title == "New name" && session.error == nil)
    }
}
