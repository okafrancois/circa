import Foundation
import BrowserEngine
import OrbitChromiumBridge

extension ChromiumSurface: BrowserLinkReopening {
    // The isolated world cannot be called or replaced by page scripts. Native Option-click
    // normally starts a download before CEF asks its navigation delegate, so intercept the
    // trusted link gesture before that default action. Forms and scripted clicks are excluded.
    // NAV-INITIATOR: the same world announces its execution context (at start, before a pointer or
    // key gesture, and when the page returns from the back-forward cache) so the shell can open a
    // link again from this document instead of loading it by URL: `__orbitOpenLink` (a `noopener`
    // window) and `__orbitFollowLink` (this tab) keep the document as the request's initiator.
    static let optionLinkScript = #"""
    (() => {
      if (window.top !== window || globalThis.__orbitOptionLinksInstalled) return;
      globalThis.__orbitOptionLinksInstalled = true;
      const open = window.open.bind(window);
      const assign = location.assign.bind(location);
      const web = href => { try { return ['http:', 'https:'].includes(new URL(href).protocol); } catch { return false; } };
      globalThis.__orbitOpenLink = href => web(href) && (open(href, '_blank', 'noopener'), true);
      globalThis.__orbitFollowLink = href => web(href) && (assign(href), true);
      let announced = false;
      const announce = () => {
        if (announced || typeof globalThis.__orbitOptionLink !== 'function') return;
        announced = true;
        globalThis.__orbitOptionLink('orbit:document');
      };
      announce();
      addEventListener('DOMContentLoaded', announce, true);
      addEventListener('pointerdown', event => { if (event.isTrusted) announce(); }, true);
      addEventListener('keydown', event => { if (event.isTrusted) announce(); }, true);
      addEventListener('pageshow', event => { if (event.persisted) { announced = false; announce(); } }, true);
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

    static let documentAnnouncement = "orbit:document"

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
              let text = object["payload"] as? String, text.utf8.count <= 8192 else { return }
        let context = object["executionContextId"] as? Int
        if text == Self.documentAnnouncement {
            linkDocumentContext = context
            return
        }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return }
        if let context { linkDocumentContext = context }
        let action = BrowserNavigationAction(url: url, isMainFrame: true, modifiers: [.option], kind: .linkActivation,
            httpMethod: "GET", hasBody: false, isUserGesture: true)
        let decision = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) { _ in }
        delegate?.surface(self, decidePolicyFor: action, decision: decision)
        decision.endSynchronousTurn()
        guard decision.policy == .allow else { return }
        // Followed in this tab from the document itself (renderer-initiated); by URL only if that fails.
        guard let context else { navigate(to: url); return }
        Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            if await !self.evaluateInLinkWorld("__orbitFollowLink", url: url, context: context) {
                guard !self.isDisposed else { return }
                self.navigate(to: url)
            }
        }
    }

    // MARK: NAV-INITIATOR

    public func reopenLinkFromDocument(_ url: URL, modifiers: BrowserModifierKeys,
                                       fallback: @escaping @MainActor () -> Void) -> Bool {
        reopenLinkFromDocument(url, modifiers: modifiers, disposition: .newForegroundTab, fallback: fallback)
    }

    func reopenLinkFromDocument(_ url: URL, modifiers: BrowserModifierKeys, disposition: BrowserNavigationDisposition,
                                fallback: @escaping @MainActor () -> Void) -> Bool {
        guard !isDisposed, isBrowserCreated, webContent == nil, let context = linkDocumentContext,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return false }
        let id = linkReopens.begin(url: url, modifiers: modifiers, disposition: disposition)
        onEngineEvent?("link-reopen", ["modifiers": String(modifiers.rawValue), "disposition": disposition.rawValue])
        Task { @MainActor [weak self] in
            guard let self else { return }
            let evaluated = await self.evaluateInLinkWorld("__orbitOpenLink", url: url, context: context)
            // The popup request (OnBeforePopup) precedes the evaluation result; a reopen still
            // waiting now never reached the delegate.
            if self.linkReopens.finish(id) {
                self.onEngineEvent?("link-reopen-fallback", ["evaluated": String(evaluated)])
                guard !self.isDisposed else { return }
                fallback()
            }
        }
        return true
    }

    /// Calls a function of the OrbitOptionLinks world with a user gesture; true when it ran and
    /// accepted the URL.
    func evaluateInLinkWorld(_ function: String, url: URL, context: Int) async -> Bool {
        guard let argument = try? JSONSerialization.data(withJSONObject: [url.absoluteString]),
              let list = String(data: argument, encoding: .utf8) else { return false }
        let expression = "globalThis.\(function)(...\(list))"
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "expression": expression, "contextId": context, "userGesture": true,
            "returnByValue": true, "silent": true,
        ] as [String: Any]), let parameters = String(data: data, encoding: .utf8) else { return false }
        let (success, result) = await devToolsCall("Runtime.evaluate", params: parameters, timeout: .seconds(3))
        guard success, let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              object["exceptionDetails"] == nil,
              let value = object["result"] as? [String: Any] else { return false }
        return value["value"] as? Bool == true
    }
}
