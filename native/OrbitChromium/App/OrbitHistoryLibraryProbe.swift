import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Qualification restricted to a signed synthetic bundle and its own window/profile.
@MainActor
enum OrbitHistoryLibraryProbe {
    static let bundleID = "lab.orbit.orbit.history-library"
    static func run(_ owner: OrbitWindowController, environment: OrbitEnvironment,
                    command: [String: String], root: URL) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true,
              Bundle.main.object(forInfoDictionaryKey: "OrbitUseMockKeychain") as? Bool == true,
              let profile = owner.session.activeProfileID, let window = owner.window,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
              windows.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) else { return ["refused": true] }
        if command["step"] == "native" {
            let delegate = HistoryDelegate()
            let surface = environment.engine.makeSurface(profileID: profile, delegate: delegate)
            defer { surface.dispose() }
            surface.navigate(to: URL(string: "chrome://history/")!)
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(50))
                if surface.isReady && !surface.navigationState.isLoading,
                   surface.navigationState.committedURL?.host == "history" { break }
            }
            try? await Task.sleep(for: .seconds(1))
            let native = await OrbitPerformanceProbe.evaluate(surface, "(() => { const a=document.querySelector('history-app'); const l=a?.shadowRoot?.querySelector('history-list'); return {app:!!a, list:!!l, count:l?.historyData_?.length ?? -1, hasShellFixture:l?.historyData_?.some(x=>x.url==='https://history.test/imported-only') ?? false}; })()") ?? [:]
            return ["native": native, "committed": surface.navigationState.committedURL?.absoluteString ?? "", "shellCount": owner.library.history.visits.count]
        }
        if command["step"] == "seed" {
            let visits = (0..<32).map { index in
                BrowserHistoryVisit(url: URL(string: index == 0 ? "https://history.test/imported-only" : "https://history.test/synthetic/\(index)?value=123")!,
                    title: "Synthetic history title with a deliberately long readable name \(index)",
                    visitedAt: Date().addingTimeInterval(-Double(index) * 3600))
            }
            do { _ = try await owner.library.history.recorder.importDocument(.init(profileID: profile, visits: visits)) }
            catch { return ["seedFailed": true] }
        }
        owner.showLibrary(.history)
        await owner.session.waitForQueuedCommands()
        await owner.library.history.task?.value
        window.setFrame(NSRect(x: 100, y: 100, width: 1100, height: 780), display: true)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        return ["visits": owner.library.history.visits.count, "rows": owner.library.historyView.rows.count,
                "window": window.windowNumber, "pid": getpid()]
    }

    private final class HistoryDelegate: BrowserEngineSurfaceDelegate {
        typealias Surface = ChromiumSurface
        func surfaceDidStartNavigation(_ surface: Surface) {}
        func surfaceDidCommitNavigation(_ surface: Surface) {}
        func surfaceDidFinishNavigation(_ surface: Surface) {}
        func surfaceDidFailNavigation(_ surface: Surface) {}
        func surfaceDidRequestClose(_ surface: Surface) {}
        func surface(_ surface: Surface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
        func surface(_ surface: Surface, createSurfaceFor request: BrowserNewSurfaceRequest, make: () -> Surface) -> Surface? { nil }
        func surface(_ surface: Surface, decidePolicyFor action: BrowserNavigationAction,
                     decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
            decision.decide(action.url?.absoluteString == "chrome://history/" ? .allow : .cancel)
        }
    }
}
