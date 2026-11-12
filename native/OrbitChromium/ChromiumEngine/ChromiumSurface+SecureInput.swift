import Foundation
import OrbitChromiumBridge

extension ChromiumSurface {
    // Only a focus notification crosses this isolated-world binding, never field contents. CEF
    // remains the authority that enables secure input, including nested frames.
    static let secureInputFocusScript = #"""
    (() => {
      const report = () => globalThis.__orbitSecureFocus('changed');
      addEventListener('focusin', report, true);
      addEventListener('focusout', () => queueMicrotask(report), true);
    })();
    """#

    func installSecureInputFocus() {
        _ = ACRExecuteDevToolsMethod(token, "Runtime.addBinding",
            #"{"name":"__orbitSecureFocus","executionContextName":"OrbitSecureFocus"}"#)
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "source": Self.secureInputFocusScript, "worldName": "OrbitSecureFocus"
        ]), let parameters = String(data: data, encoding: .utf8) else { return }
        _ = ACRExecuteDevToolsMethod(token, "Page.addScriptToEvaluateOnNewDocument", parameters)
    }

    func receiveSecureInputFocus(_ payload: Data) {
        guard !isDisposed,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["name"] as? String == "__orbitSecureFocus",
              object["payload"] as? String == "changed" else { return }
        secureInputDocumentDidLoad()
        secureInputFocusChanged()
    }
}
