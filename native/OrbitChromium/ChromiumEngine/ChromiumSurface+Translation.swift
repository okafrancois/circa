import Foundation
import OrbitChromiumBridge
import BrowserEngine

extension ChromiumSurface {
    /// Chromium validates its own service configuration before accepting this command.
    public func requestBuiltInTranslation() -> Bool {
        !isDisposed && isReady && ACRExecuteChromeCommand(token, "IDC_SHOW_TRANSLATE") == 1
    }

    public var supportsPageTranslation: Bool { true }

    public func translationSample() async throws -> BrowserTranslationSample {
        let value = try await translationEvaluate(#"({text:document.body?.innerText.slice(0,16000) || '',language:document.documentElement.lang})"#)
        guard let sample = value as? [String: String] else { throw BrowserEngineError.unsupportedOperation }
        return BrowserTranslationSample(text: sample["text"] ?? "", language: sample["language"] ?? "")
    }

    public func translationTexts() async throws -> [BrowserTranslationText] {
        let value = try await translationEvaluate(Self.translationScript + ";orbitTranslation.take()")
        guard let array = value as? [[String: String]] else { throw BrowserEngineError.unsupportedOperation }
        return array.compactMap { row in
            guard let id = row["id"], let text = row["text"] else { return nil }
            return BrowserTranslationText(id: id, text: text)
        }
    }

    public func applyTranslation(_ texts: [BrowserTranslationText]) async throws {
        let data = try JSONEncoder().encode(texts)
        _ = try await translationEvaluate("orbitTranslation.apply(" + String(decoding: data, as: UTF8.self) + ")")
    }

    public func restoreTranslation() async throws {
        _ = try await translationEvaluate("globalThis.orbitTranslation?.restore() ?? true")
    }

    private func translationEvaluate(_ expression: String) async throws -> Any {
        let generation = documentGeneration
        guard !isDisposed, !navigationState.isLoading,
              let url = navigationState.committedURL, ["https", "http"].contains(url.scheme) else {
            throw BrowserEngineError.unsupportedOperation
        }
        if translationWorld?.generation != generation {
            let (ok, result) = await devToolsCall("Page.getFrameTree")
            guard ok, let json = try JSONSerialization.jsonObject(with: result) as? [String: Any],
                  let tree = json["frameTree"] as? [String: Any], let frame = tree["frame"] as? [String: Any],
                  let id = frame["id"] as? String else { throw BrowserEngineError.unsupportedOperation }
            let params = try JSONSerialization.data(withJSONObject: ["frameId": id, "worldName": "OrbitTranslation"])
            let (created, world) = await devToolsCall("Page.createIsolatedWorld", params: String(decoding: params, as: UTF8.self))
            guard created, let json = try JSONSerialization.jsonObject(with: world) as? [String: Any],
                  let context = json["executionContextId"] as? Int, documentGeneration == generation else {
                throw BrowserEngineError.documentChanged
            }
            translationWorld = (generation, context)
        }
        guard let context = translationWorld?.context, documentGeneration == generation else { throw BrowserEngineError.documentChanged }
        let params = try JSONSerialization.data(withJSONObject: ["contextId": context, "expression": expression, "returnByValue": true])
        let (ok, result) = await devToolsCall("Runtime.evaluate", params: String(decoding: params, as: UTF8.self))
        guard documentGeneration == generation, !isDisposed else { throw BrowserEngineError.documentChanged }
        guard ok, let json = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              json["exceptionDetails"] == nil, let remote = json["result"] as? [String: Any] else {
            throw BrowserEngineError.unsupportedOperation
        }
        return remote["value"] ?? NSNull()
    }

    // The isolated world retains node identity; page handlers, markup and form values stay intact.
    // Conditional writes preserve changes made by the page while a batch is in flight.
    private static let translationScript = #"""
    if (!globalThis.orbitTranslation) globalThis.orbitTranslation = (() => {
      const records = new Map(), ids = new WeakMap(); let next = 0;
      const excluded = 'script,style,noscript,textarea,input,select,option,code,pre,[contenteditable]:not([contenteditable="false"]),[translate="no"],.notranslate';
      function eligible(n) {
        const p = n.parentElement;
        if (!n.isConnected || !p || p.closest(excluded) || !p.checkVisibility({checkOpacity:true,checkVisibilityCSS:true})) return false;
        const language = p.closest('[lang]')?.lang;
        if (language && language.split('-')[0] !== document.documentElement.lang.split('-')[0]) return false;
        const rect = p.getBoundingClientRect();
        return rect.bottom >= -200 && rect.top <= innerHeight + 200 && /\p{L}/u.test(n.data) && n.data.length <= 2000;
      }
      return {
        take() {
          for (const [id,r] of records) if (!r.node.isConnected) records.delete(id);
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const batch = []; let size = 0, n;
          while ((n = walker.nextNode())) {
            if (!eligible(n)) continue;
            let id = ids.get(n), r = records.get(id);
            if (r && n.data === r.translated) continue;
            if (batch.length >= 32 || size + n.data.length > 4000) break;
            if (!id) { id = String(++next); ids.set(n,id); }
            r = {node:n,original:n.data,translated:null}; records.set(id,r);
            batch.push({id,text:n.data}); size += n.data.length;
          }
          return batch;
        },
        apply(batch) {
          for (const item of batch) {
            const r = records.get(item.id);
            if (r && eligible(r.node) && r.node.data === r.original) {
              const leading = r.original.match(/^\s*/u)[0], trailing = r.original.match(/\s*$/u)[0];
              r.translated = leading + item.text.trim() + trailing; r.node.data = r.translated;
            }
          }
          return true;
        },
        restore() {
          for (const r of records.values()) if (r.node.isConnected && r.translated !== null && r.node.data === r.translated) r.node.data = r.original;
          records.clear(); return true;
        }
      };
    })()
    """#
}
