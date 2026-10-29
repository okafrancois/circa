import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite("Boost menu and code editing")
@MainActor
struct BrowserBoostMenuCodeTests {
    @Test func supportedMenuResetPersistsAndRetainsIdentity() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("boost-menu-code-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile = ProfileID()
        let store = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        session.edit {
            $0.fontFamily = "Courier"; $0.textZoom = 1.5; $0.textTransform = .uppercase
            $0.colorScheme = .init(); $0.zapSelectors = ["p"]
            $0.customCSS = "body { color: red }"; $0.customJavaScript = "document.title = 'fixture'"
        }
        session.setJavaScriptConsent(true)
        await session.pending?.value
        let view = BrowserBoostEditorView(session: session, firstRun: false)
        let menu = view.makeHeaderMenu()
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Reset all Edits", "Delete this Boost", "All Boosts…"])
        let reset = try #require(menu.items.first)
        #expect(NSApplication.shared.sendAction(try #require(reset.action), to: reset.target, from: reset))
        await session.pending?.value
        let reloaded = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        let saved = try #require(await reloaded.snapshot().boosts.first)
        #expect(saved.id == session.boost.id && saved.title == "Synthetic")
        #expect(saved.content == BrowserBoostContent() && !saved.javaScriptOptIn)
        #expect(BrowserLibraryBoostsView.matches(saved, query: "Synthetic"))
        #expect(try BrowserBoostCompiler.compile(saved).css.isEmpty)
    }

    @Test func codeEditsPersistBuffersAndRequireExplicitScriptConsent() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("boost-menu-code-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile = ProfileID()
        let store = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        let view = BrowserBoostCodeView(session: session)
        view.textView.string = "p { color: green }"
        view.textDidChange(Notification(name: NSText.didChangeNotification))
        var requests = 0
        view.requestJavaScriptConsent = { completion in requests += 1; completion(false) }
        view.selectCSS(false)
        await view.selectionTask?.value
        #expect(requests == 1 && view.isCSS)
        #expect(!session.boost.javaScriptOptIn)
        #expect(session.boost.content.customCSS == "p { color: green }")
        view.requestJavaScriptConsent = { completion in requests += 1; completion(true) }
        view.selectCSS(false)
        await view.selectionTask?.value
        #expect(!view.isCSS && requests == 2)
        view.textView.string = "document.body.dataset.sample = 'yes'"
        view.textDidChange(Notification(name: NSText.didChangeNotification))
        await session.pending?.value
        #expect(try BrowserBoostCompiler.compile(session.boost).isolatedJavaScript == view.textView.string)
        session.setJavaScriptConsent(false)
        await session.pending?.value
        #expect(try BrowserBoostCompiler.compile(session.boost).isolatedJavaScript == nil)
        #expect(!session.boost.content.customJavaScript.isEmpty)
        view.selectCSS(true)
        await view.selectionTask?.value
        #expect(view.isCSS && view.textView.string == "p { color: green }")
        let reloaded = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        let saved = try #require(await reloaded.snapshot().boosts.first)
        #expect(saved.content == session.boost.content && !saved.javaScriptOptIn)
    }

    @Test func deleteCancelAcceptAndQueuedEditsDoNotRecreateBoost() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("boost-menu-code-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile = ProfileID()
        let store = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        var accepted = false
        let cancel = BrowserBoostDeleteView { accepted = $0; if $0 { session.delete() } }
        cancel.finish(false); cancel.finish(true)
        #expect(!accepted && !session.isClosed)
        #expect(await store.snapshot().boosts.count == 1)
        session.edit { $0.customCSS = "p { color: red }" }
        let delete = BrowserBoostDeleteView { if $0 { session.delete() } }
        delete.finish(true)
        session.edit { $0.customCSS = "Ignored" }
        await session.pending?.value
        #expect(session.isDeleted && session.error == nil)
        #expect(await store.snapshot().boosts.isEmpty)
        let reloaded = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root))
        #expect(await reloaded.snapshot().boosts.isEmpty)
    }
}
