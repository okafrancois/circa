import AppKit
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
                    fixture: URL, root: URL, record: (String, String, [String: Any]) -> Void) async {
        func check(_ name: String, _ value: Bool) { record("live-folders." + name, value ? "proven" : "failed", [:]) }
        do {
            guard let context = await window.session.captureContextInCommandOrder().value else { throw BrowserStoreError.windowMissing }
            var historyChanged = false
            ChromiumGitHubDiagnostics.phase = { if $0 == "sameDocumentHistoryChanged" { historyChanged = true } }
            defer { ChromiumGitHubDiagnostics.phase = nil }
            let session = FixtureGitHubSession(engine: environment.engine, origin: fixture)
            let runtime = BrowserLiveFoldersRuntime(store: environment.store, session: session, directory: nil)
            window.liveFoldersRuntime = runtime
            defer { window.liveFoldersRuntime = environment.liveFolders }
            let visible = CommandLine.arguments.contains("--orbit-smoke-live-folders-visible")
            func gate() -> Bool {
                if !visible { return true }
                guard let native = window.window, NSApp.keyWindow === native,
                      NSRunningApplication.current.isActive,
                      let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(native.windowNumber)) as? [[String: Any]],
                      rows.first?[kCGWindowOwnerPID as String] as? Int32 == getpid() else {
                    check("owned-input", false); return false
                }
                return true
            }
            func invoke(_ item: NSMenuItem) -> Bool {
                guard gate(), let action = item.action, let target = item.target as? NSObject else { return false }
                target.perform(action, with: item)
                return true
            }
            if visible, let native = window.window {
                let capability: [String: Any] = ["pid": getpid(), "mode": "visible-input", "windowNumber": native.windowNumber]
                try JSONSerialization.data(withJSONObject: capability).write(to: root.appendingPathComponent("visible-window.json"))
                window.showWindow(nil); native.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(200))
            }
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
            let creation = try require(window.makeLiveFoldersCreationMenu(spaceID: context.spaceID)?.submenu?.items.first)
            check("native-activation", invoke(creation))
            let creationDeadline = ContinuousClock.now.advanced(by: .seconds(12))
            var after = await environment.store.sessionDocument()
            while !after.organization.tabs.contains(where: { $0.liveFolderChild != nil }), ContinuousClock.now < creationDeadline {
                try await Task.sleep(for: .milliseconds(25))
                after = await environment.store.sessionDocument()
            }
            let id = try require(after.organization.folders.first { $0.liveFolder != nil }?.id)
            await window.session.waitForPendingCommands()
            window.session.synchronizeOrganization()
            await window.session.waitForPendingCommands()
            let folder = try require(window.session.organization?.item(for: .folder(id)))
            guard case let .folder(folderItem) = folder, let config = folderItem.liveFolder else { throw BrowserGitHubProviderError.invalidResponse }
            let nativeMenu = try require(window.makeLiveFolderContextMenu(folder: folderItem, configuration: config)?.menu)
            let filters = try require(nativeMenu.items.first?.submenu)
            check("same-document-history-fetch", historyChanged)
            _ = try await environment.engine.conformanceProbe?.evaluateScript("document.cookie='orbit-live-folder-history=unknown; path=/'; 'ok'", in: surface)
            do {
                _ = try await session.pullRequests(profileID: context.profileID, query: "is:pr is:open", page: 1)
                check("unknown-history-route-rejected", false)
            } catch BrowserGitHubProviderError.invalidResponse { check("unknown-history-route-rejected", true) }
            _ = try await environment.engine.conformanceProbe?.evaluateScript("document.cookie='orbit-live-folder-history=; Max-Age=0; path=/'; 'ok'", in: surface)
            check("native-filter-defaults", filters.items.filter { $0.state == .on }.count == 2)
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.window?.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(650))
                window.window?.contentView?.layoutSubtreeIfNeeded()
                if let view = window.window?.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: image)
                    try image.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("live-folder-" + theme + ".png"))
                }
            }
            let review = try require(filters.items.last)
            check("native-filter-action", invoke(review))
            let filterDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await runtime.configuration(id)?.filters.contains(.reviewRequested) == true, ContinuousClock.now < filterDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            check("native-filter-applied", await runtime.configuration(id)?.filters == [.authored])
            let activeConnection = try await runtime.connection(context.profileID)
            while activeConnection.state == .refreshing, ContinuousClock.now < filterDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            after = await environment.store.sessionDocument()
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
            if let row = refreshed.organization.tabs.first(where: { $0.liveFolderChild?.folderID == id }), gate() {
                window.session.synchronizeOrganization()
                await window.session.waitForPendingCommands()
                window.session.selectTab(row.id)
                await window.session.waitForPendingCommands()
                let openDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                while window.session.selectedSurface?.navigationState.url != row.url, ContinuousClock.now < openDeadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                check("row-opens-owning-profile", window.session.selectedSurface?.profileID == context.profileID
                    && window.session.selectedSurface?.navigationState.url == row.url)
            } else { check("row-opens-owning-profile", false) }
            let connection = try await runtime.connection(context.profileID)
            await connection.disconnect()
            let disconnected = await environment.store.sessionDocument()
            check("disconnect-revokes-cache", !disconnected.organization.tabs.contains { $0.liveFolderChild?.folderID == id })
            let conversionContext = try require(await window.session.captureContextInCommandOrder().value)
            _ = try await environment.store.convertFolderToSpace(ordinary, from: conversionContext)
            let converted = await environment.store.sessionDocument()
            check("ordinary-conversion-distinct", converted.spaces.count == before.spaces.count + 1 && converted.organization.folders.contains { $0.id == id })
            await runtime.stop()
        } catch { record("live-folders.execution", "failed", ["errorType": String(describing: type(of: error)), "providerError": (error as? BrowserGitHubProviderError).map { String(describing: $0) } ?? "none"]) }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw BrowserGitHubProviderError.invalidResponse }
        return value
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
