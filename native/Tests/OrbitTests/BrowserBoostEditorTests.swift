import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import Testing
@testable import Orbit

@Suite("Boost editor transactions")
@MainActor
struct BrowserBoostEditorTests {
    @Test func rapidEditsPreserveFieldsAndDrainOnClose() async throws {
        let profile = ProfileID(), runtime = BrowserBoostsRuntime(), engine = BoostEditorEngine()
        let store = try runtime.store(for: profile)
        let editor = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "http://127.0.0.1:9187/fixture")!, title: "Synthetic")
        editor.onCommit = { try await runtime.synchronize(profileID: profile, enabled: true, engine: engine) }
        editor.edit { $0.fontFamily = "Avenir" }
        editor.edit { $0.customCSS = "p { color: red }" }
        editor.edit { $0.customJavaScript = "document.body.dataset.sample = 'yes'" }
        editor.zap(".fixture"); editor.zap(".fixture")
        editor.close()
        editor.edit { $0.fontFamily = "Ignored" }
        await editor.pending?.value
        #expect(editor.error == nil)
        let saved = try #require(await store.snapshot().boosts.first)
        #expect(saved.content.fontFamily == "Avenir")
        #expect(saved.content.zapSelectors == [".fixture"])
        #expect(saved.content.customJavaScript.contains("sample"))
        let payload = try #require(engine.host.profiles[profile]?.boosts.first)
        #expect(payload.css.contains("p { color: red }"))
        #expect(payload.css.contains("display: none"))
        #expect(payload.isolatedJavaScript == nil)
        #expect(saved.hostPattern.port == 9187)
        #expect(saved.hostPattern.schemes == [.http])
        #expect(await store.matchTable().matching(URL(string: "http://127.0.0.1:9187/elsewhere")!, in: profile).count == 1)
    }

    @Test func acceptedEditOutlivesItsClosedWindow() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        var editor: BrowserBoostEditorSession? = try await .create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        editor?.edit { $0.textTransform = .uppercase }
        editor?.close()
        let pending = editor?.pending
        editor = nil
        await pending?.value
        #expect(await store.snapshot().boosts.first?.content.textTransform == .uppercase)
    }

    @Test func staleEditorCannotOverwriteAnotherWindow() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let first = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        let second = BrowserBoostEditorSession(store: store, boost: first.boost)
        first.edit { $0.textTransform = .uppercase }; await first.pending?.value
        second.edit { $0.fontFamily = "Courier" }; await second.pending?.value
        #expect(second.error as? BrowserBoostError == .staleRevision)
        #expect(await store.snapshot().boosts.first?.content.fontFamily == nil)
        #expect(await store.snapshot().boosts.first?.content.textTransform == .uppercase)
    }

    @Test func unzapColorIntentAndSearch() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let editor = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Café")
        editor.zap("button"); editor.unzap("button")
        editor.edit { var color = BrowserBoostColorScheme(); color.contrast = 0.4; color.originalSaturation = 0.8; $0.colorScheme = color }
        await editor.pending?.value
        #expect(editor.boost.content.zapSelectors.isEmpty)
        let compiled = try BrowserBoostCompiler.compile(editor.boost)
        #expect(compiled.css.isEmpty)
        #expect(BrowserLibraryBoostsView.matches(editor.boost, query: "CAFE"))
        #expect(BrowserLibraryBoostsView.matches(editor.boost, query: "example"))
        #expect(!BrowserLibraryBoostsView.matches(editor.boost, query: "missing"))
        editor.resetColors(); await editor.pending?.value
        #expect(editor.boost.content.colorScheme == nil)
    }

    @Test func existingConsentedSourceRemainsInProtocolPayload() async throws {
        let profile = ProfileID(), runtime = BrowserBoostsRuntime(), engine = BoostEditorEngine()
        let store = try runtime.store(for: profile)
        var content = BrowserBoostContent()
        content.customCSS = "body { color: green }"
        content.customJavaScript = "document.body.dataset.boost = 'ready'"
        let saved = try await store.save(.init(title: "Synthetic", hostPattern: .init(host: "example.test"), content: content, javaScriptOptIn: true))
        let editor = BrowserBoostEditorSession(store: store, boost: saved)
        editor.onCommit = { try await runtime.synchronize(profileID: profile, enabled: true, engine: engine) }
        editor.edit { $0.fontFamily = "Courier" }; await editor.pending?.value
        #expect(engine.host.profiles[profile]?.boosts.first?.isolatedJavaScript == content.customJavaScript)
        #expect(engine.host.profiles[profile]?.boosts.first?.css.contains(content.customCSS) == true)
    }

    @Test func disablingIncludesInactiveLoadedProfiles() async throws {
        let runtime = BrowserBoostsRuntime(), engine = BoostEditorEngine()
        let profiles = [ProfileID(), ProfileID()]
        for profile in profiles {
            let store = try runtime.store(for: profile)
            _ = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
            try await runtime.synchronize(profileID: profile, enabled: true, engine: engine)
        }
        #expect(runtime.loadedProfileIDs == Set(profiles))
        for profile in runtime.loadedProfileIDs {
            try await runtime.synchronize(profileID: profile, enabled: false, engine: engine)
        }
        #expect(profiles.allSatisfy { engine.host.profiles[$0]?.boosts.isEmpty == true })
    }

    @Test func pickerCoordinatesAndNoPersistentInjectionFallback() async throws {
        let source = BrowserBoostZapView.script(at: NSPoint(x: 300, y: 150), zoom: 1.5)
        #expect(source.contains("elementFromPoint(200.0, 100.0)"))
        #expect(!source.contains("display:"))
        let host = BrowserFakeBoostHost(), engine = SyntheticEngine()
        let profile = ProfileID(), runtime = BrowserBoostsRuntime(hostOverride: host)
        let store = try runtime.store(for: profile)
        _ = try await BrowserBoostEditorSession.create(in: store, url: URL(string: "https://example.test")!, title: "Synthetic")
        try await runtime.synchronize(profileID: profile, enabled: true, engine: engine)
        #expect(host.profiles[profile]?.boosts.count == 1)
        try await runtime.synchronize(profileID: profile, enabled: false, engine: engine)
        #expect(host.profiles[profile]?.boosts.isEmpty == true)
        await engine.shutdown()
    }
}

@MainActor
private final class BoostEditorEngine: BrowserEngine {
    let backend = SyntheticEngine(), host = BrowserFakeBoostHost()
    let kind = BrowserEngineKind.synthetic
    var capabilities: BrowserEngineCapabilities { [.boosts] }
    var boosts: (any BrowserBoostHost)? { host }
    var extensions: (any BrowserExtensionHost)? { nil }
    func profile(for profileID: ProfileID) -> BrowserEngineProfile { backend.profile(for: profileID) }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<SyntheticSurface>) -> SyntheticSurface {
        backend.makeSurface(profileID: profileID, delegate: delegate)
    }
    func shutdown() async { await backend.shutdown() }
}
