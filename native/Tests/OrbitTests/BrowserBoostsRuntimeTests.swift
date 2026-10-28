import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import Foundation
import Testing
@testable import Orbit

@MainActor
private final class BoostTestEngine: BrowserEngine {
    let backend = SyntheticEngine()
    let host = BrowserFakeBoostHost()
    let kind = BrowserEngineKind.synthetic
    var capabilities: BrowserEngineCapabilities = [.boosts]
    var boosts: (any BrowserBoostHost)? { host }
    var extensions: (any BrowserExtensionHost)? { nil }
    func profile(for profileID: ProfileID) -> BrowserEngineProfile { backend.profile(for: profileID) }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<SyntheticSurface>) -> SyntheticSurface {
        backend.makeSurface(profileID: profileID, delegate: delegate)
    }
    func shutdown() async { await backend.shutdown() }
}

@Suite("Boost shell ownership without visible surfaces")
@MainActor
struct BrowserBoostsRuntimeTests {
    @Test func profileStoresRegistryDisableAndRemoval() async throws {
        let runtime = BrowserBoostsRuntime(), engine = BoostTestEngine(), profile = ProfileID()
        let first = try runtime.store(for: profile)
        #expect(first === (try runtime.store(for: profile)))
        #expect(first !== (try runtime.store(for: ProfileID())))
        let boost = BrowserBoost(title: "Synthetic", hostPattern: try .init(host: "example.test"))
        try await first.save(boost)
        try await runtime.synchronize(profileID: profile, enabled: true, engine: engine)
        #expect(engine.host.profiles[profile]?.boosts.map(\.id) == [boost.id])
        #expect(runtime.acknowledgements[profile]?.revision == 1)
        try await runtime.synchronize(profileID: profile, enabled: false, engine: engine)
        #expect(engine.host.profiles[profile]?.boosts.isEmpty == true)
        #expect(await first.snapshot().boosts == [boost])
        try await runtime.synchronize(profileID: profile, enabled: true, engine: engine)
        try await runtime.removeProfile(profile, engine: engine)
        #expect(engine.host.profiles[profile]?.boosts.isEmpty == true)
        #expect(await first.snapshot().boosts.isEmpty)
        engine.capabilities = []
        await #expect(throws: BrowserEngineError.unsupportedOperation) {
            try await runtime.synchronize(profileID: profile, enabled: true, engine: engine)
        }
    }

    @Test func persistentProfilesPreloadBeforeEnvironmentReturns() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("OrbitBoostPreload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = BrowserStore()
        let profile = await seed.createProfile(name: "Synthetic")
        _ = try await seed.createSpace(name: "Synthetic", profileID: profile)
        let session = root.appendingPathComponent("session.json")
        try BrowserSessionFileStore().save(await seed.sessionDocument(), to: session)
        let saved = try BrowserBoostStore(profileID: profile, persistence: .profileDirectory(root.appendingPathComponent("Boosts")))
        let boost = try await saved.save(.init(title: "Persisted", hostPattern: try .init(host: "example.test")))
        let engine = BoostTestEngine()
        let environment = try await BrowserEnvironment.open(engine: engine, sessionFile: session)
        #expect(engine.host.profiles[profile]?.boosts.map(\.id) == [boost.id])
        #expect(environment.boosts.acknowledgements[profile] != nil)
        try await environment.settings.setEnablesBoostsOnWebsites(false)
        for _ in 0..<50 {
            if engine.host.profiles[profile]?.boosts.isEmpty == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.host.profiles[profile]?.boosts.isEmpty == true)
        #expect(await saved.snapshot().boosts.count == 1)
        await engine.shutdown()
    }

    @Test func privateEnvironmentDoesNotInheritDiskBoosts() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("OrbitBoostShell-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let disk = BrowserBoostsRuntime(directory: root)
        let saved = try disk.store(for: profile)
        try await saved.save(.init(title: "Regular only", hostPattern: try .init(host: "example.test")))
        let file = root.appendingPathComponent(profile.rawValue.uuidString).appendingPathComponent("boosts.json")
        let before = try Data(contentsOf: file)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let memory = try environment.boosts.store(for: profile)
        #expect(await memory.snapshot().boosts.isEmpty)
        try await memory.save(.init(title: "Private only", hostPattern: try .init(host: "private.test")))
        try await environment.settings.setEnablesBoostsOnWebsites(false)
        #expect(try Data(contentsOf: file) == before)
        #expect(await saved.snapshot().boosts.first?.title == "Regular only")
        #expect(BrowserSettingsRuntime.enablesBoostsTitle == "Enable Boosts on websites you visit")
        await environment.engine.shutdown()
    }
}
