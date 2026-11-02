import BrowserEngine
import Foundation

extension ChromiumSurface: BrowserLinkPreviewSource {
    public func previewLink(at point: CGPoint, revision: UInt64,
                            isCurrent: @escaping @MainActor () -> Bool) async throws -> BrowserLinkPreviewTarget? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            guard isCurrent(), documentGeneration == revision, !isDisposed else { throw BrowserEngineError.documentChanged }
            let data = try JSONSerialization.data(withJSONObject: params)
            let (ok, reply) = await devToolsCall(method, params: String(decoding: data, as: UTF8.self))
            guard ok, isCurrent(), documentGeneration == revision, !isDisposed,
                  let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { throw BrowserEngineError.documentChanged }
            return result
        }
        let tree = try await call("Page.getFrameTree")
        guard let node = tree["frameTree"] as? [String: Any], let frame = node["frame"] as? [String: Any],
              let id = frame["id"] as? String else { return nil }
        let world = try await call("Page.createIsolatedWorld", ["frameId": id, "worldName": "OrbitLinkPreviewData"])
        guard let context = world["executionContextId"] as? Int else { return nil }
        let expression = """
        (()=>{const e=document.elementFromPoint(\(point.x / pageZoom),\(point.y / pageZoom))?.closest('a[href]');
        if(!e||e.closest('[hidden],[inert],[aria-hidden="true"],form,[contenteditable]'))return null;
        const s=getComputedStyle(e);if(s.display==='none'||s.visibility!=='visible'||Number(s.opacity)===0)return null;
        const r=e.getBoundingClientRect();if(!r.width||!r.height)return null;
        const ids=globalThis.__orbitPreviewIDs||(globalThis.__orbitPreviewIDs=new WeakMap());
        if(!ids.has(e))ids.set(e,String(globalThis.__orbitPreviewSequence=(globalThis.__orbitPreviewSequence||0)+1));
        return {id:ids.get(e),url:e.href,title:(e.innerText||e.getAttribute('aria-label')||'').trim().slice(0,240),description:(e.title||'').trim().slice(0,500),x:r.x,y:r.y,width:r.width,height:r.height}})()
        """
        let reply = try await call("Runtime.evaluate", ["contextId": context, "expression": expression, "returnByValue": true])
        guard let value = (reply["result"] as? [String: Any])?["value"] as? [String: Any],
              let identity = value["id"] as? String, let raw = value["url"] as? String,
              raw.utf8.count <= 8192, let url = URL(string: raw), let title = value["title"] as? String,
              let description = value["description"] as? String,
              let x = value["x"] as? Double, let y = value["y"] as? Double,
              let width = value["width"] as? Double, let height = value["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite) else { return nil }
        return .init(id: identity, url: url, title: title, description: description,
                     bounds: CGRect(x: x * pageZoom, y: y * pageZoom, width: width * pageZoom, height: height * pageZoom))
    }
}
