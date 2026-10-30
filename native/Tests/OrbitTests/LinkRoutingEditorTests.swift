import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct LinkRoutingEditorTests {
    @Test("Inline edits retain the latest draft while earlier writes are pending; removal rejects stale input")
    func editThenRemove() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (_, profile) = try await environment.initialContext.value
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let editor = BrowserLinkRoutingEditor(model: model)
        editor.load()
        editor.add()
        let id = try #require(editor.routes.first?.id)
        var release: CheckedContinuation<Void, Never>?
        model.perform { await withCheckedContinuation { release = $0 } }
        try await withNativeTestDeadline("Routing write gate", timeout: 3) {
            while release == nil { await Task.yield() }
        }
        editor.update(id, keyPath: \.value, value: "example.org/first")
        editor.update(id, keyPath: \.value, value: "")
        #expect(editor.routes.first?.value == "")
        editor.update(id, keyPath: \.value, value: "example.org/final")
        editor.remove(id)
        #expect(editor.routes.isEmpty)
        editor.update(id, keyPath: \.value, value: "example.org/stale")
        release?.resume()
        await model.waitForPendingActions()
        #expect(model.errorMessage == nil)
        #expect(await environment.settings.store.snapshot().linkRouting.rules.isEmpty)
        editor.load()
        #expect(editor.routes.isEmpty)
    }

    @Test("Edits follow route identity across reordering and reopening; invalid drafts remain local")
    func editsAndOrder() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let other = try await environment.store.createSpace(name: "Routing Target", profileID: profile)
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let editor = BrowserLinkRoutingEditor(model: model)
        editor.add()
        let first = try #require(editor.routes.first?.id)
        editor.update(first, keyPath: \.value, value: "example.org")
        editor.add()
        let second = try #require(editor.routes.last?.id)
        editor.update(second, keyPath: \.value, value: "/docs")
        editor.move(second, offset: -1)
        editor.update(first, keyPath: \.match, value: .host)
        editor.update(first, keyPath: \.spaceID, value: other)
        editor.update(second, keyPath: \.value, value: "/docs/final")
        let expected = [BrowserLinkRoute(id: second, value: "/docs/final", spaceID: space),
                        BrowserLinkRoute(id: first, match: .host, value: "example.org", spaceID: other)]
        await model.waitForPendingActions()
        #expect(model.errorMessage == nil)
        #expect(editor.routes == expected)
        let reopened = BrowserLinkRoutingEditor(model: model)
        reopened.load()
        #expect(reopened.routes == expected)
        reopened.update(first, keyPath: \.value, value: "\n")
        await model.waitForPendingActions()
        #expect(await environment.settings.store.snapshot().linkRouting.rules == expected)
        #expect(reopened.routes.last?.isValid == false)
        reopened.remove(first)
        await model.waitForPendingActions()
        #expect(await environment.settings.store.snapshot().linkRouting.rules == [expected[0]])
    }

    @Test("Deleting an untouched new draft preserves saved routes and the default")
    func removeUnsavedDraft() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (_, profile) = try await environment.initialContext.value
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let before = environment.settings.document.linkRouting
        let editor = BrowserLinkRoutingEditor(model: model)
        editor.load()
        editor.add()
        editor.remove(try #require(editor.routes.last?.id))
        await model.waitForPendingActions()
        #expect(await environment.settings.store.snapshot().linkRouting == before)
    }
}
}
