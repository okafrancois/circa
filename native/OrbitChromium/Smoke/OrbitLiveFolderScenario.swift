import BrowserCore
import BrowserEngine
@_spi(Testing) import ChromiumEngine
import Foundation

@MainActor
private final class FixtureGitHubSession: BrowserGitHubWebSession {
    let engine: ChromiumBrowserEngine
    let origin: URL
    init(engine: ChromiumBrowserEngine, origin: URL) { self.engine = engine; self.origin = origin }
    func pullRequests(profileID: ProfileID, query: String, page: Int) async throws -> BrowserProfileWebResponse {
        try await engine.pullRequestsFixture(profileID: profileID, query: query, page: page, origin: origin)
    }
}

@MainActor
enum OrbitLiveFolderScenario {
    static func run(environment: BrowserEnvironment<ChromiumBrowserEngine>, window: OrbitWindowController,
                    fixture: URL, record: (String, String, [String: Any]) -> Void) async {
        func check(_ name: String, _ value: Bool) { record("live-folders." + name, value ? "proven" : "failed", [:]) }
        do {
            guard let context = await window.session.captureContextInCommandOrder().value else { throw BrowserStoreError.windowMissing }
            let session = FixtureGitHubSession(engine: environment.engine, origin: fixture)
            let runtime = BrowserLiveFoldersRuntime(store: environment.store, session: session, directory: nil)
            let other = ProfileID()
            let signedOut = try await session.pullRequests(profileID: other, query: "is:pr is:open", page: 1)
            do { _ = try BrowserGitHubWebPage(html: signedOut.body); check("signed-out", false) }
            catch BrowserGitHubProviderError.signedOut { check("signed-out", true) }
            let owner = FixtureDelegate()
            let surface = environment.engine.makeSurface(profileID: context.profileID, delegate: owner)
            defer { surface.dispose() }
            surface.navigate(to: fixture.appendingPathComponent("pulls"))
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !owner.loaded && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            guard owner.loaded else { throw BrowserGitHubProviderError.invalidResponse }
            try await environment.engine.conformanceProbe?.writeSiteDataMarker("fixture", for: fixture, through: surface)
            _ = try await environment.engine.conformanceProbe?.evaluateScript("document.cookie='orbit-live-folder=fixture; path=/'; 'ok'", in: surface)
            let (ordinary, _) = try await environment.store.createFolder(title: "Pull Requests", at: .init(.pinned(context.spaceID)), containing: [], from: context)
            let before = await environment.store.sessionDocument()
            let id = try await runtime.enable(configuration: .init(filters: [.authored]), context: context)
            let after = await environment.store.sessionDocument()
            check("no-space-created", before.spaces == after.spaces)
            check("provider-row", after.organization.tabs.contains { $0.liveFolderChild?.folderID == id && $0.pageTitle == "Synthetic change" })
            check("ordinary-folder-preserved", after.organization.folders.first { $0.id == ordinary }?.liveFolder == nil)
            try await runtime.configure(id, configuration: .init(filters: [.authored], excludedRepositories: ["example/fixture"]), context: context)
            let filtered = await environment.store.sessionDocument()
            check("repository-filter", !filtered.organization.tabs.contains { $0.liveFolderChild?.folderID == id })
            try await runtime.configure(id, configuration: .init(filters: [.authored]), context: context)
            let refreshed = await environment.store.sessionDocument()
            check("refresh-restores-stable-identity", refreshed.organization.tabs.first { $0.liveFolderChild?.folderID == id }?.id == after.organization.tabs.first { $0.liveFolderChild?.folderID == id }?.id)
            let isolated = try await session.pullRequests(profileID: other, query: "is:pr is:open", page: 1)
            do { _ = try BrowserGitHubWebPage(html: isolated.body); check("profile-isolation", false) }
            catch BrowserGitHubProviderError.signedOut { check("profile-isolation", true) }
            let connection = try await runtime.connection(context.profileID)
            await connection.disconnect()
            let disconnected = await environment.store.sessionDocument()
            check("disconnect-revokes-cache", !disconnected.organization.tabs.contains { $0.liveFolderChild?.folderID == id })
            _ = try await environment.store.convertFolderToSpace(ordinary, from: context)
            let converted = await environment.store.sessionDocument()
            check("ordinary-conversion-distinct", converted.spaces.count == before.spaces.count + 1 && converted.organization.folders.contains { $0.id == id })
            await runtime.stop()
        } catch { record("live-folders.execution", "failed", ["errorType": String(describing: type(of: error)), "providerError": (error as? BrowserGitHubProviderError).map { String(describing: $0) } ?? "none"]) }
    }

    private final class FixtureDelegate: BrowserEngineSurfaceDelegate {
        var loaded = false
        func surfaceDidStartNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidFinishNavigation(_ surface: ChromiumSurface) { loaded = true }
        func surfaceDidFailNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidRequestClose(_ surface: ChromiumSurface) {}
        func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction, decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
        func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest, make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
        func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
    }
}
