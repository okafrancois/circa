import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

/// Update qualification only: signs synthetic profiles in to the harness's loopback
/// authentication fixture and reports what the fixture answered. Real Chromium requests carry
/// the cookies; the fixture, not this probe, judges them. Opens only http://127.0.0.1:<port>.
@MainActor
enum OrbitAuthCookieProbe {
    /// `base`: fixture origin. `phase`: label echoed to the fixture. `steps`: comma-separated
    /// fixture paths (`login`, `login2`, `whoami`). `second`: UUID of a second persistent
    /// profile; the first is the profile of the window's first Space.
    static func run(environment: OrbitEnvironment, command: [String: String]) async -> [String: Any] {
        guard let base = command["base"].flatMap(URL.init(string:)), base.scheme == "http",
              base.host == "127.0.0.1", base.port != nil, base.path.isEmpty || base.path == "/",
              let phase = command["phase"], !phase.isEmpty else { return ["error": "fixture"] }
        let steps = (command["steps"] ?? "whoami").split(separator: ",").map(String.init)
        guard !steps.isEmpty, steps.allSatisfy({ ["login", "login2", "whoami"].contains($0) }) else {
            return ["error": "steps"]
        }
        let catalog = await environment.store.catalogSnapshot()
        guard let first = catalog.spaces.first?.profileID else { return ["error": "space"] }
        var profiles = [("A", first)]
        if let second = command["second"].flatMap(UUID.init(uuidString:)), second != first.rawValue {
            profiles.append(("B", ProfileID(second)))
        }
        var report: [String: Any] = ["phase": phase]
        for (label, profileID) in profiles {
            let delegate = Delegate()
            let surface = environment.engine.makeSurface(profileID: profileID, delegate: delegate)
            defer { surface.dispose() }
            var answers: [String: String] = [:]
            for step in steps {
                var components = URLComponents(url: base.appendingPathComponent(step), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "profile", value: label), URLQueryItem(name: "phase", value: phase)]
                guard let url = components.url else { break }
                surface.navigate(to: url)
                guard await loaded(surface, url) else { answers[step] = "load-failed"; break }
                answers[step] = await bodyText(surface) ?? "unreadable"
            }
            report[label] = answers
        }
        return report
    }

    private static func loaded(_ surface: ChromiumSurface, _ url: URL) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            if surface.isReady, !surface.navigationState.isLoading, surface.navigationState.committedURL == url { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static func bodyText(_ surface: ChromiumSurface) async -> String? {
        // The fixture's answer, then the cookie names visible to the page (HttpOnly ones must not be).
        let expression = "(document.body ? document.body.innerText.trim() : '') + ' js=' + "
            + "document.cookie.split(';').map(c => c.split('=')[0].trim()).filter(Boolean).sort().join(',')"
        let parameters: [String: Any] = ["expression": expression, "returnByValue": true]
        guard let data = try? JSONSerialization.data(withJSONObject: parameters) else { return nil }
        let (ok, result) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: data, as: UTF8.self),
                                                      timeout: .seconds(5))
        guard ok, let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              let value = (object["result"] as? [String: Any])?["value"] as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class Delegate: BrowserEngineSurfaceDelegate {
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
