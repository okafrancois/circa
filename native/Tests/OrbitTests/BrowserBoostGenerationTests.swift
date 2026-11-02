import AppKit
import BrowserCore
import Foundation
import Testing
@testable import Orbit

private actor BoostDraftProvider: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID = .codex
    var requests: [BrowserAITurnRequest] = []
    func status(refresh: Bool) async -> BrowserAIProviderStatus { .init(id: id, state: .signedOut) }
    func shutdown() async {}
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        requests.append(request)
        return .init(events: AsyncStream { out in
            out.yield(.text("p { ")); out.yield(.text("display: none; }")); out.yield(.completed); out.finish()
        }, interrupt: {})
    }
}

@Suite @MainActor struct BrowserBoostGenerationTests {
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }
    @Test func promptEditsRevokeTheDraftWithoutAutosavingOrRetrying() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        let draft = BrowserBoostGeneration(session: session), provider = BoostDraftProvider()
        let view = BrowserBoostCodeView(session: session, generation: draft)
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true
        let initial = preferences, baseline = await store.snapshot()
        draft.capture = { .init(choice: .init(provider: .codex), client: provider, preferences: { initial }, isCurrent: { true }, read: { "Synthetic page" }, preview: { _, _ in true }, clear: { _ in }) }
        draft.run(" ")
        #expect(draft.error.isEmpty && !draft.running)
        #expect(await provider.requests.isEmpty)
        draft.run("Hide paragraphs"); await settle { !draft.running }
        #expect(draft.ready)
        view.prompt.stringValue = "A different change"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.prompt))
        #expect(!draft.ready && !draft.isDraftVisible && !draft.running)
        #expect(await store.snapshot() == baseline)
        #expect(await provider.requests.count == 1)
    }

    @Test func manualCodeEditsRemainVisibleWithGenerationInstalled() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        let generation = BrowserBoostGeneration(session: session)
        let view = BrowserBoostCodeView(session: session, generation: generation)
        for source in ["b", "bo", "bod", "body"] {
            view.textView.string = source
            view.textDidChange(Notification(name: NSText.didChangeNotification))
            #expect(view.textView.string == source)
        }
        await session.pending?.value
        #expect(session.boost.content.customCSS == "body")
        #expect(view.textView.string == "body")
    }

    @Test func streamedDraftIsSeparateAndOnlyApplyPersists() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        session.edit { $0.customCSS = "body { color: red; }" }; await session.pending?.value
        let baseline = await store.snapshot(), provider = BoostDraftProvider(), draft = BrowserBoostGeneration(session: session)
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true
        let initial = preferences
        var previews = 0, clears = 0, streamed: [String] = []
        draft.capture = { .init(choice: .init(provider: .codex, model: "chat-model"), client: provider,
            preferences: { initial }, isCurrent: { true }, read: { "Synthetic visible page" },
            preview: { text, _ in
                #expect(await store.snapshot() == baseline)
                #expect(text == "p { display: none; }"); previews += 1; return true
            }, clear: { _ in clears += 1 }) }
        draft.onChange = { if draft.running { streamed.append(draft.output) } }
        draft.run("Hide paragraphs")
        await settle { !draft.running }
        #expect(draft.ready && previews == 1)
        #expect(streamed.contains("p { "))
        #expect(await store.snapshot() == baseline)
        #expect(await provider.requests.first?.model == "chat-model")
        draft.apply(); await settle { !draft.applying }
        #expect(await store.snapshot().boosts.first?.content.customCSS == "p { display: none; }")
        #expect(clears == 1)
    }
    @Test func storeChangesRejectPreviewAndStopRejectsQueuedWork() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        let draft = BrowserBoostGeneration(session: session), provider = BoostDraftProvider()
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true
        let initial = preferences
        var previews = 0
        draft.capture = { .init(choice: .init(provider: .codex), client: provider, preferences: { initial }, isCurrent: { true }, read: {
            _ = try await store.update(session.boost.id) { $0.title = "Changed elsewhere" }
            return "Synthetic page"
        }, preview: { _, _ in previews += 1; return true }, clear: { _ in }) }
        draft.run("Hide paragraphs"); await settle { !draft.running }
        #expect(previews == 0 && !draft.ready)
        #expect(await store.snapshot().boosts.first?.content.customCSS == "")
        draft.run("Hide paragraphs"); draft.stop()
        await settle { !draft.running }
        #expect(!draft.ready && previews == 0)
    }
    @Test func editedGeneratedCodeRemainsStagedAndInvalidApplyPreservesSavedCSS() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        let draft = BrowserBoostGeneration(session: session), provider = BoostDraftProvider()
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true
        let initial = preferences, baseline = await store.snapshot()
        draft.capture = { .init(choice: .init(provider: .codex), client: provider, preferences: { initial }, isCurrent: { true }, read: { "Synthetic page" }, preview: { text, _ in text != "invalid" }, clear: { _ in }) }
        draft.run("Hide paragraphs"); await settle { !draft.running }
        draft.editDraft("")
        #expect(draft.isDraftVisible && draft.output.isEmpty)
        #expect(await store.snapshot() == baseline)
        draft.editDraft("invalid")
        #expect(await store.snapshot() == baseline)
        draft.apply(); await settle { !draft.applying }
        #expect(!draft.error.isEmpty)
        #expect(await store.snapshot() == baseline)
        draft.editDraft("p { color: red; }")
        draft.apply(); await settle { !draft.applying }
        #expect(await store.snapshot().boosts.first?.content.customCSS == "p { color: red; }")
    }

    @Test func revocationAfterStoreAwaitRestoresSavedCSS() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        session.edit { $0.customCSS = "body { color: red; }" }; await session.pending?.value
        let expected = await store.snapshot()
        var checks = 0
        do {
            try await session.applyGeneratedCSS("p { display: none; }", expected: expected, isCurrent: { checks += 1; return checks < 3 })
            Issue.record("Revoked apply completed")
        } catch is CancellationError {}
        #expect(await store.snapshot().boosts.first?.content.customCSS == "body { color: red; }")
    }
    @Test func renameDuringApplyPreservesRenameAndOriginalCSS() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        session.edit { $0.customCSS = "body { color: red; }" }; await session.pending?.value
        let expected = await store.snapshot()
        var current = true, renamed = false
        session.onInvalidateDraft = { current = false }
        session.onCommit = {
            if !renamed { renamed = true; session.rename(to: "Renamed during apply"); await session.pending?.value }
        }
        do {
            try await session.applyGeneratedCSS("p { display: none; }", expected: expected, isCurrent: { current })
            Issue.record("Renamed apply completed")
        } catch is CancellationError {}
        #expect(await store.snapshot().boosts.first?.title == "Renamed during apply")
        #expect(await store.snapshot().boosts.first?.content.customCSS == "body { color: red; }")
    }

    @Test func manualEditsInvalidateGeneratedDraftWithoutSavingGeneratedCode() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let session = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        let draft = BrowserBoostGeneration(session: session), provider = BoostDraftProvider()
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true
        let initial = preferences
        draft.capture = { .init(choice: .init(provider: .codex), client: provider, preferences: { initial }, isCurrent: { true }, read: { "Synthetic page" }, preview: { _, _ in true }, clear: { _ in }) }
        draft.run("Hide paragraphs"); await settle { !draft.running }
        #expect(draft.ready)
        session.rename(to: "Renamed"); await session.pending?.value
        #expect(!draft.ready && draft.output.isEmpty)
        #expect(await store.snapshot().boosts.first?.content.customCSS == "")
        draft.run(String(repeating: "🐈", count: 1100))
        #expect(!draft.running && !draft.ready)
        #expect(await provider.requests.count == 1)
    }
}
