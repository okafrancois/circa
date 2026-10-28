import AppKit
import BrowserCore
import ChromiumEngine
import Foundation

/// Two real product windows and persistent CEF profiles on the same loopback origin.
/// The runner relaunches this scenario normally and after its existing SIGKILL phase.
@MainActor
enum OrbitProfileScenarios {
    static func run(application: OrbitApplication, environment: OrbitEnvironment,
                    fixture: URL, restoring: Bool,
                    record: (String, String, [String: Any]) -> Void) async {
        func check(_ name: String, _ value: Bool, _ evidence: [String: Any] = [:]) {
            record("profiles." + name, value ? "proven" : "failed", evidence)
        }
        let page = URL(string: "/page?case=profile-accounts", relativeTo: fixture)!.absoluteURL
        let origin = URL(string: "/", relativeTo: fixture)!.absoluteURL
        do {
            if !restoring {
                let profile = await environment.store.createProfile(name: "Synthetic Account B")
                let space = try await environment.store.createSpace(name: "Synthetic Account B", profileID: profile)
                let id = UUID()
                application.windows.newWindow(id: id)
                await application.windows.waitForPendingCommands()
                guard let second = application.windows.windows[id] else { check("second-window", false); return }
                second.session.activateSpace(space)
                await second.session.waitForPendingCommands()
                for controller in application.windows.windows.values { controller.submitAddress(page.absoluteString) }
            }
            let windows = application.windows.windows.values.sorted { $0.id.uuidString < $1.id.uuidString }
            let ready = await OrbitRelaunchScenarios.until {
                windows.count == 2 && windows.allSatisfy {
                    $0.session.selectedSurface?.isReady == true
                        && $0.session.selectedSurface?.navigationState.isLoading == false
                        && $0.session.selectedSurface?.navigationState.committedURL?.host == fixture.host
                }
            }
            guard ready, let probe = environment.engine.conformanceProbe else {
                check("windows-ready", false); return
            }
            let profiles = Set(windows.compactMap { $0.session.activeProfileID })
            check("windows-and-profiles", profiles.count == 2 && windows.allSatisfy {
                $0.session.selectedSurface?.profileID == $0.session.activeProfileID
            }, ["windows": windows.count, "profiles": profiles.count, "restoring": restoring])
            for controller in windows {
                guard let surface = controller.session.selectedSurface else { continue }
                let marker = "synthetic-account-" + surface.profileID.rawValue.uuidString.lowercased()
                if !restoring {
                    try await probe.writeSiteDataMarker(marker, for: origin, through: surface)
                    _ = try await probe.evaluateScript("localStorage.setItem('core-profile-account', '\(marker)'); 'ok'", in: surface)
                }
            }
            // Read only after both writes, so a shared context cannot accidentally pass.
            for (index, controller) in windows.enumerated() {
                guard let surface = controller.session.selectedSurface else { continue }
                let marker = "synthetic-account-" + surface.profileID.rawValue.uuidString.lowercased()
                let cookie = try await probe.readSiteDataMarker(for: origin, through: surface)
                let storage = try await probe.evaluateScript("localStorage.getItem('core-profile-account')", in: surface)
                check((restoring ? "restored-account-" : "isolated-account-") + String(index), cookie == marker && storage == marker,
                      ["cookieMatches": cookie == marker, "storageMatches": storage == marker])
                let extra = URL(string: "/page?case=profile-secondary-tab", relativeTo: fixture)!.absoluteURL
                controller.openTab(url: extra)
                let loaded = await OrbitRelaunchScenarios.until {
                    controller.session.selectedSurface?.navigationState.committedURL == extra
                        && controller.session.selectedSurface?.navigationState.isLoading == false
                }
                if let sibling = controller.session.selectedSurface {
                    let siblingCookie = try await probe.readSiteDataMarker(for: origin, through: sibling)
                    check("secondary-tab-account-" + String(index), loaded && siblingCookie == marker && sibling.profileID == surface.profileID)
                }
            }
            try await environment.saveNow()
            check("saved", true)
        } catch { check("scenario", false, ["kind": String(describing: error)]) }
    }
}
