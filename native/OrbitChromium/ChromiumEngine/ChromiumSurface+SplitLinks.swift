import Foundation
import BrowserEngine
import OrbitChromiumBridge

extension ChromiumSurface {
    // The isolated world cannot be called or replaced by page scripts. Native Option-click
    // normally starts a download before CEF asks its navigation delegate, so intercept the
    // trusted link gesture before that default action. Forms and scripted clicks are excluded.
    static let optionLinkScript = #"""
    (() => {
      if (window.top !== window || globalThis.__orbitOptionLinksInstalled) return;
      globalThis.__orbitOptionLinksInstalled = true;
      addEventListener('click', event => {
        if (!event.isTrusted || event.button !== 0 || !event.altKey || event.metaKey || event.ctrlKey || event.shiftKey) return;
        const link = event.composedPath().find(node => node instanceof HTMLAnchorElement && node.href);
        if (!link || typeof globalThis.__orbitOptionLink !== 'function') return;
        const url = new URL(link.href);
        if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        globalThis.__orbitOptionLink(url.href);
      }, true);
    })();
    """#

    func installOptionLinks() {
        _ = ACRExecuteDevToolsMethod(token, "Runtime.enable", "{}")
        _ = ACRExecuteDevToolsMethod(token, "Runtime.addBinding",
            #"{"name":"__orbitOptionLink","executionContextName":"OrbitOptionLinks"}"#)
        guard let data = try? JSONSerialization.data(withJSONObject: ["source": Self.optionLinkScript, "worldName": "OrbitOptionLinks"]),
              let parameters = String(data: data, encoding: .utf8) else { return }
        _ = ACRExecuteDevToolsMethod(token, "Page.addScriptToEvaluateOnNewDocument", parameters)
    }

    func receiveOptionLink(_ payload: Data) {
        guard !isDisposed,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["name"] as? String == "__orbitOptionLink",
              let text = object["payload"] as? String, text.utf8.count <= 8192,
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return }
        let action = BrowserNavigationAction(url: url, isMainFrame: true, modifiers: [.option], kind: .linkActivation,
            httpMethod: "GET", hasBody: false, isUserGesture: true)
        let decision = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) { _ in }
        delegate?.surface(self, decidePolicyFor: action, decision: decision)
        decision.endSynchronousTurn()
        if decision.policy == .allow { navigate(to: url) }
    }
}
