import Foundation
import AppKit
import BrowserEngine

extension ChromiumSurface: BrowserAIPageReading {
    public func highlightAIPassage(_ passage: String, revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard isCurrent(), documentGeneration == revision, !isDisposed else { throw BrowserEngineError.documentChanged }
        let (ok, data) = await devToolsCall("Page.getFrameTree")
        guard ok, let tree = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = tree["frameTree"] as? [String: Any], let frame = node["frame"] as? [String: Any],
              let id = frame["id"] as? String else { return false }
        let params = try JSONSerialization.data(withJSONObject: ["frameId": id, "worldName": "OrbitAssistantData"])
        let (created, worldData) = await devToolsCall("Page.createIsolatedWorld", params: String(decoding: params, as: UTF8.self))
        guard created, isCurrent(), documentGeneration == revision, let world = try JSONSerialization.jsonObject(with: worldData) as? [String: Any], let context = world["executionContextId"] as? Int else { return false }
        let encoded = String(decoding: try JSONEncoder().encode(passage), as: UTF8.self)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let script = """
        (()=>{const q=\(encoded);const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n,c=0;while((n=w.nextNode())&&c++<50000){const e=n.parentElement;if(!e||e.closest('form,input,textarea,select,script,style,[hidden],[aria-hidden="true"],[contenteditable]')||!e.getClientRects().length)continue;const i=n.textContent.indexOf(q);if(i<0)continue;const r=document.createRange();r.setStart(n,i);r.setEnd(n,i+q.length);const m=document.createElement('mark');r.surroundContents(m);const reduced=\(reduced ? "true" : "false");const start=scrollY,target=Math.max(0,scrollY+m.getBoundingClientRect().top-innerHeight/2);if(reduced){scrollTo(0,target)}else{const begin=performance.now();const curve=(t,p,q)=>3*(1-t)*(1-t)*t*p+3*(1-t)*t*t*q+t*t*t;const tick=now=>{const x=Math.min(1,(now-begin)/500);let lo=0,hi=1;for(let i=0;i<18;i++){const mid=(lo+hi)/2;if(curve(mid,.19,.22)<x)lo=mid;else hi=mid}scrollTo(0,start+(target-start)*curve((lo+hi)/2,1,1));if(x<1)requestAnimationFrame(tick)};requestAnimationFrame(tick)};m.animate([{backgroundColor:'transparent'},{backgroundColor:'#ffcc00'}],{duration:reduced?150:250,fill:'forwards'});setTimeout(()=>{m.animate([{backgroundColor:'#ffcc00'},{backgroundColor:'transparent'}],{duration:reduced?150:600}).finished.then(()=>m.replaceWith(...m.childNodes))},2650);return true}return false})()
        """
        let eval = try JSONSerialization.data(withJSONObject: ["contextId": context, "expression": script, "returnByValue": true])
        guard isCurrent(), documentGeneration == revision else { throw BrowserEngineError.documentChanged }
        let (_, result) = await devToolsCall("Runtime.evaluate", params: String(decoding: eval, as: UTF8.self))
        guard isCurrent(), documentGeneration == revision else { throw BrowserEngineError.documentChanged }
        let json = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        return (json?["result"] as? [String: Any])?["value"] as? Bool == true
    }
    public func readAIPage(revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> String {
        func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            guard isCurrent(), documentGeneration == revision, !isDisposed else { throw BrowserEngineError.documentChanged }
            let data = try JSONSerialization.data(withJSONObject: params)
            let (ok, reply) = await devToolsCall(method, params: String(decoding: data, as: UTF8.self))
            guard ok, isCurrent(), documentGeneration == revision, !isDisposed,
                  let json = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { throw BrowserEngineError.documentChanged }
            return json
        }
        let tree = try await call("Page.getFrameTree")
        guard let node = tree["frameTree"] as? [String: Any], let frame = node["frame"] as? [String: Any], let id = frame["id"] as? String else { throw BrowserEngineError.unsupportedOperation }
        let world = try await call("Page.createIsolatedWorld", ["frameId": id, "worldName": "OrbitAssistantData"])
        guard let context = world["executionContextId"] as? Int else { throw BrowserEngineError.unsupportedOperation }
        let expression = """
        (() => {const out=[];let size=0,count=0;const walk=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);while(walk.nextNode()&&size<24000&&count++<50000){const n=walk.currentNode,e=n.parentElement;if(!e||e.closest('input,textarea,select,button,form,script,style,noscript,[hidden],[aria-hidden="true"],[contenteditable]'))continue;let hidden=false;for(let a=e;a;a=a.parentElement){const s=getComputedStyle(a);if(s.display==='none'||s.visibility!=='visible'||Number(s.opacity)===0){hidden=true;break}}if(hidden||!e.getClientRects().length)continue;const t=n.textContent.trim().slice(0,24000-size);if(t){out.push(t);size+=t.length}}return out.join('\\n').slice(0,24000)})()
        """
        let reply = try await call("Runtime.evaluate", ["contextId": context, "expression": expression, "returnByValue": true])
        guard let result = reply["result"] as? [String: Any], let text = result["value"] as? String else { throw BrowserEngineError.unsupportedOperation }
        return text
    }
}
