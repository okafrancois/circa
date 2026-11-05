import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine

extension OrbitSmokeDriver {
    /// The per-site AI exclusion list on a real committed page whose host uses an underscore
    /// label. Synthetic AI clients only: no installed AI program is started or queried.
    func aiSiteExclusionScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        func check(_ name: String, _ passed: Bool, _ evidence: [String: Any] = [:]) {
            self.check("ai-site-exclusion." + name, passed, evidence)
        }
        // Ordered but off screen, like the pane capture: no input, nothing on the owner's display.
        owner.window?.setFrameOrigin(NSPoint(x: -8000, y: 0))
        owner.window?.orderFront(nil)
        environment.ai.terminateNow()
        _ = await until(10) { !environment.ai.isChecking }
        for id in [BrowserAIProviderID.codex, .claudeCode] {
            let client = OrbitAssistantFixtureClient(id: id, root: runRoot)
            environment.ai.clientOverrides[id] = client
            environment.ai.statuses[id] = await client.status(refresh: false)
        }
        // The same loopback fixture under a *.localhost name, which the engine resolves to
        // loopback itself. The label keeps an underscore, as some real hosts do.
        var components = URLComponents(url: fixture, resolvingAgainstBaseURL: false)
        components?.host = "team_a.localhost"
        guard let page = components?.url else { check("fixture-host", false); return }
        let host = page.host ?? ""
        check("fixture-host", host == "team_a.localhost", ["url": page.absoluteString])
        check("settings-accepts-host", BrowserAIPolicy.site(from: host) == host.lowercased())
        let excluded = BrowserAIPolicy.adding("localhost", to: []) ?? []
        try? await environment.settings.updateAI {
            $0.isEnabled = true
            $0.readsCurrentTabOnRequest = true
            $0.disabledSites = excluded
        }
        owner.openTab(url: page)
        let surface = await committed(owner, page)
        let committedHost = surface?.navigationState.committedURL?.host
        check("page-committed", surface != nil && committedHost == host, ["committedHost": committedHost ?? ""])
        guard let tabID = owner.session.organization?.selectedTab?.id.rawValue else { check("tab", false); return }
        func shared() -> Bool { owner.assistantSources.contains { $0.id == tabID } }
        let preferencesApplied = await until(5) { owner.settingsPreferences?.runtime.document.ai.disabledSites == excluded }
        check("excluded", preferencesApplied && owner.assistantEnabled && !shared(),
              ["disabledSites": excluded, "assistantEnabled": owner.assistantEnabled, "shared": shared()])
        try? await environment.settings.updateAI { $0.disabledSites = [] }
        let control = await until(5) { shared() }
        check("shared-without-exclusion", control, ["shared": control])
    }
}
