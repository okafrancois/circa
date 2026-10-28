import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

/// Opt-in hidden, mock-only probe, compiled only into the existing confined smoke bundle.
/// Backend evidence only: no Incognito menus, private-window design or Orbit sharing policy.
@MainActor
enum OrbitPrivateDomainProbe {
    static let requiredResults = ["private.normal-ready", "private.same-origin-isolated",
        "private.memory-services", "private.no-profile-directory", "private.last-owner-release",
        "private.fresh-context", "private.normal-survives", "private.no-session-sentinel"]

    static func run(application: OrbitApplication, environment normal: OrbitEnvironment, window: OrbitWindowController,
                    configuration: OrbitProductConfiguration, fixture: URL,
                    record: (String, String, [String: Any]) -> Void) async {
        func check(_ id: String, _ value: Bool) { record(id, value ? "proven" : "failed", [:]) }
        let engine = normal.engine
        guard configuration.usesMockKeychain, engine.patchLevel >= 3, engine.essentialsLevel >= 1,
              engine.surfaceMode == .hosted else {
            record("private.approved-runtime-required", "failed", [:]); return
        }
        let page = URL(string: "/page?case=private-domain-synthetic", relativeTo: fixture)!.absoluteURL
        let origin = URL(string: "/", relativeTo: fixture)!.absoluteURL
        let delegate = ProbeDelegate()
        var owned: [(BrowserPrivateDomainScope<ChromiumBrowserEngine>, BrowserPrivateDomainLease)] = []
        var privateFactory: BrowserPrivateDomainFactory<ChromiumBrowserEngine>?
        do {
            window.submitAddress(page.absoluteString)
            guard await wait({ window.session.selectedSurface?.navigationState.committedURL == page }),
                  let normalSurface = window.session.selectedSurface, let normalProbe = engine.conformanceProbe else {
                check("private.normal-ready", false); return
            }
            check("private.normal-ready", true)
            try await normalProbe.writeSiteDataMarker("normal-domain", for: origin, through: normalSurface)
            _ = try await normalProbe.evaluateScript("localStorage.setItem('private-domain-probe', 'normal-domain'); 'ok'", in: normalSurface)
            var privateEngines: [ChromiumBrowserEngine] = []
            let factory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: {
                let engine = makePrivateEngine(); privateEngines.append(engine); return engine
            })
            privateFactory = factory
            let scope = factory.makeScope()
            let a = try await scope.acquire()
            owned = [(scope, a)]
            let b = try await scope.acquire()
            owned.append((scope, b))
            let memory = try scope.environment(for: b)
            let profileID = try scope.profileID(for: b)
            let surface = try scope.makeSurface(for: b, delegate: delegate)
            surface.navigate(to: page)
            guard await wait({ surface.navigationState.committedURL == page }),
                  let probe = memory.engine.conformanceProbe else { throw ProbeError.navigation }
            let emptyCookie = try await probe.readSiteDataMarker(for: origin, through: surface)
            let emptyStorage = try await probe.evaluateScript("localStorage.getItem('private-domain-probe') || 'empty'", in: surface)
            check("private.same-origin-isolated", emptyCookie == nil && emptyStorage == "empty")
            let sentinel = "private-domain-fixture-sentinel"
            try await probe.writeSiteDataMarker(sentinel, for: origin, through: surface)
            _ = try await probe.evaluateScript("localStorage.setItem('private-domain-probe', '\(sentinel)'); 'ok'", in: surface)
            check("private.memory-services", memory !== normal && memory.store !== normal.store
                && memory.sessionFile == nil && memory.historyRecorder !== normal.historyRecorder
                && memory.permissions !== normal.permissions && memory.downloads !== normal.downloads)
            let directory = URL(fileURLWithPath: ChromiumRuntime.shared.rootCachePath)
                .appendingPathComponent("profile-" + profileID.rawValue.uuidString.lowercased())
            check("private.no-profile-directory", !FileManager.default.fileExists(atPath: directory.path))
            try await normal.saveNow()
            let session = try Data(contentsOf: configuration.sessionFile)
            check("private.no-session-sentinel", session.range(of: Data(sentinel.utf8)) == nil)
            try await scope.release(a)
            guard !scope.isClosed else { throw ProbeError.earlyRelease }
            try await scope.release(b)
            owned.removeAll()
            check("private.last-owner-release", scope.isClosed && surface.isTeardownComplete
                && memory.engine.liveNativeTokens.isEmpty && memory.engine.profileCount == 0
                && memory.engine.holdingWindowTabCount == 0 && !memory.engine.isShutDown
                && ChromiumRuntime.shared.isReady && !ChromiumRuntime.shared.isQuitting)

            let fresh = factory.makeScope()
            let c = try await fresh.acquire()
            owned = [(fresh, c)]
            let next = try fresh.makeSurface(for: c, delegate: delegate)
            let nextMemory = try fresh.environment(for: c)
            next.navigate(to: page)
            guard await wait({ next.navigationState.committedURL == page }),
                  let nextProbe = nextMemory.engine.conformanceProbe else { throw ProbeError.navigation }
            let nextCookie = try await nextProbe.readSiteDataMarker(for: origin, through: next)
            let nextStorage = try await nextProbe.evaluateScript("localStorage.getItem('private-domain-probe') || 'empty'", in: next)
            check("private.fresh-context", try fresh.profileID(for: c) != profileID && nextCookie == nil
                && nextStorage == "empty" && privateEngines.count == 2)
            try await fresh.release(c)
            owned.removeAll()
            let normalCookie = try await normalProbe.readSiteDataMarker(for: origin, through: normalSurface)
            let normalStorage = try await normalProbe.evaluateScript("localStorage.getItem('private-domain-probe')", in: normalSurface)
            check("private.normal-survives", normalCookie == "normal-domain" && normalStorage == "normal-domain"
                && !normalSurface.isDisposed && !engine.isShutDown && !engine.liveNativeTokens.isEmpty)
        } catch {
            record("private.probe-error", "failed", ["kind": String(describing: error)])
        }
        // A failed probe cannot abandon its scope and silently let runtime quit mask cleanup.
        for (scope, lease) in owned.reversed() {
            do { try await scope.release(lease) }
            catch { record("private.cleanup-error", "failed", ["kind": String(describing: error)]) }
        }
        for (scope, _) in owned {
            do { try await scope.close() }
            catch { record("private.cleanup-error", "failed", ["kind": String(describing: error)]) }
        }
        do { try await privateFactory?.retryQuarantinedScopes() }
        catch { record("private.cleanup-error", "failed", ["kind": String(describing: error)]) }
        await productWindow(application, fixture: fixture, record: record)
    }

    /// Exercise the actual Incognito command, router and content host in the hidden product.
    /// DOM and geometry checks supplement isolation; they do not assert visible compositor paint.
    private static func productWindow(_ application: OrbitApplication, fixture: URL,
                                      record: (String, String, [String: Any]) -> Void) async {
        application.createPrivateCommandWindow()
        await application.waitForPrivateWindowCommands()
        guard let controller = application.windows.windows.values.first(where: { $0.isPrivateWindow }),
              let domain = application.privateWindows[controller.id] else {
            record("private.product-window-created", "failed", [:]); return
        }
        let page = URL(string: "/page?case=private-product-window", relativeTo: fixture)!.absoluteURL
        controller.palette.dismiss()
        controller.openTab(url: page)
        let committed = await wait {
            controller.session.selectedSurface?.navigationState.committedURL == page
                && controller.session.selectedSurface?.navigationState.isLoading == false
        }
        do {
            guard let surface = controller.session.selectedSurface, let probe = controller.engine.conformanceProbe else {
                throw ProbeError.navigation
            }
            let body = try await probe.evaluateScript("document.body.textContent.length > 0 ? 'content' : 'empty'", in: surface)
            let hosted = surface.hostView.window === controller.window && surface.hostView.superview != nil
                && surface.hostView.bounds.width > 100 && surface.hostView.bounds.height > 100
                && !surface.hostView.isHiddenOrHasHiddenAncestor
            record("private.product-window-document", committed && body == "content" && hosted ? "proven" : "failed",
                   ["committed": committed, "body": body, "hosted": hosted,
                    "width": surface.hostView.bounds.width, "height": surface.hostView.bounds.height,
                    "nativeSubviews": surface.hostView.subviews.count])
        } catch { record("private.product-window-document", "failed", ["kind": String(describing: error)]) }
        controller.window?.close()
        let closed = await wait { application.privateWindows[controller.id] == nil && domain.scope.isClosed }
        record("private.product-window-cleanup", closed ? "proven" : "failed", [:])
    }

    private enum ProbeError: Error { case navigation, earlyRelease }
    private static func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private final class ProbeDelegate: BrowserEngineSurfaceDelegate {
        func surfaceDidStartNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidFinishNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidFailNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidRequestClose(_ surface: ChromiumSurface) {}
        func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                     decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
        func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                     make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
        func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
    }
}
