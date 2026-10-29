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
        let value = try await translationEvaluate(BrowserTranslationScript.source + ";orbitTranslation.take()")
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

}
