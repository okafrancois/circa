import Foundation
import BrowserCore
import BrowserEngine

extension ChromiumSurface: BrowserAIErrandPageReading {
    private func errandCall(_ expression: String, revision: UInt64,
                            acceptsNavigation: Bool = false,
                            isCurrent: @escaping @MainActor () -> Bool) async throws -> Any? {
        func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            guard isCurrent(), documentGeneration == revision, !isDisposed else { throw BrowserEngineError.documentChanged }
            let data = try JSONSerialization.data(withJSONObject: params)
            let (ok, reply) = await devToolsCall(method, params: String(decoding: data, as: UTF8.self))
            guard ok, isCurrent(), (documentGeneration == revision || (acceptsNavigation && method == "Runtime.evaluate")), !isDisposed,
                  let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { throw BrowserEngineError.documentChanged }
            return result
        }
        let tree = try await call("Page.getFrameTree")
        guard let node = tree["frameTree"] as? [String: Any], let frame = node["frame"] as? [String: Any],
              let id = frame["id"] as? String else { throw BrowserEngineError.unsupportedOperation }
        let world = try await call("Page.createIsolatedWorld", ["frameId": id, "worldName": "OrbitErrandData"])
        guard let context = world["executionContextId"] as? Int else { throw BrowserEngineError.unsupportedOperation }
        let result = try await call("Runtime.evaluate", ["contextId": context, "expression": expression, "returnByValue": true, "awaitPromise": true])
        guard result["exceptionDetails"] == nil else { throw BrowserEngineError.unsupportedOperation }
        return (result["result"] as? [String: Any])?["value"]
    }

    private static func errandJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    // Everything retained here is local to one isolated main-frame execution context.
    private static let errandUtilities = #"""
    const visible=e=>{
      if(!e||!e.isConnected||e.getRootNode()!==document||!e.getClientRects().length)return false;
      if(e.closest('[hidden],[inert],[aria-hidden="true"],iframe,frame,object,embed'))return false;
      for(let a=e;a;a=a.parentElement){const s=getComputedStyle(a);if(s.display==='none'||s.visibility!=='visible'||Number(s.opacity)===0)return false}
      const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&r.bottom>0&&r.right>0&&r.top<innerHeight&&r.left<innerWidth;
    };
    const secret=e=>/password|passcode|one.time|cc-|credit|card|cvc|cvv|token|secret|auth|iban|account|routing|social|ssn/i.test([e.name,e.id,e.autocomplete,e.getAttribute('aria-label'),e.getAttribute('placeholder'),e.type].join(' '));
    const credential=e=>e instanceof HTMLInputElement&&(['password','file'].includes(e.type)||/password|cc-|credit.card|cvc|cvv|one.time/i.test([e.autocomplete,e.name,e.id].join(' ')));
    const targetVisible=e=>{if(!visible(e)||getComputedStyle(e).pointerEvents==='none')return false;const r=e.getBoundingClientRect(),h=document.elementFromPoint(Math.max(0,Math.min(innerWidth-1,r.x+r.width/2)),Math.max(0,Math.min(innerHeight-1,r.y+r.height/2)));return h===e||e.contains(h)};
    const eligible=e=>targetVisible(e)&&!e.disabled&&!e.readOnly&&!e.isContentEditable&&!secret(e)&&!(e.closest('form')&&Array.from(e.closest('form').elements).some(credential));
    const attrs=e=>JSON.stringify(Array.from(e.attributes).map(a=>[a.name,a.value]));
    const state=e=>{const f=e.form,nodes=f?Array.from(f.elements):[],r=e.getBoundingClientRect();if(nodes.length>100||e.innerHTML.length>4000)return null;const data={rect:[r.x,r.y,r.width,r.height,scrollX,scrollY],formAttrs:f?attrs(f):'',values:nodes.map(n=>[attrs(n),n.value,n.checked,n.selectedIndex]),attrs:attrs(e),value:e.value,checked:e.checked,html:e.innerHTML};if(JSON.stringify(data).length>16000)return null;return {f,nodes,data:JSON.stringify(data)}};
    const same=(e,s)=>{const n=state(e);return n&&s&&n.f===s.f&&n.nodes.length===s.nodes.length&&n.nodes.every((v,i)=>v===s.nodes[i])&&n.data===s.data};
    const clear=()=>{const l=globalThis.__orbitErrand;l?.outline?.remove();l?.cursor?.remove();if(l){l.outline=null;l.cursor=null}};
    """#

    public func observeErrandPage(tabID: UUID, revision: UInt64,
                                 isCurrent: @escaping @MainActor () -> Bool) async throws -> BrowserAIErrandPage {
        let snapshot = UUID()
        let expression = """
        (()=>{\(Self.errandUtilities)
        clear();delete globalThis.__orbitErrand;
        if(document.designMode.toLowerCase()==='on'||!document.body)return null;
        const byte=s=>new TextEncoder().encode(s).length;
        const clip=(s,max)=>{let out='';for(const c of s){if(byte(out)+byte(c)>max)break;out+=c}return out};
        const targets=[],map=new Map(),ids=\(try Self.errandJSON((0..<24).map { _ in UUID() }));let budget=8000;
        for(const e of Array.from(document.querySelectorAll('a[href],button,input,textarea,[role="button"]')).slice(0,5000)){
          if(targets.length>=24||!eligible(e))continue;
          let kind;if(e instanceof HTMLInputElement&&['submit','button','reset'].includes(e.type))kind='button';else if(e instanceof HTMLInputElement||e instanceof HTMLTextAreaElement){if(!(e instanceof HTMLTextAreaElement)&&!['text','search','url'].includes(e.type))continue;kind='text'}else kind=e instanceof HTMLAnchorElement?'link':'button';
          let destination=null;const submitsForm=kind==='button'&&!!e.form&&(e.type==='submit'||e.type==='image');
          if(kind==='link'||submitsForm){let u;try{u=new URL(kind==='link'?e.href:(e.getAttribute('formaction')?e.formAction:e.form.action))}catch{continue}if(!['http:','https:'].includes(u.protocol)||u.username||u.password||u.href.length>2048)continue;destination=u.href}
          const label=clip((e.getAttribute('aria-label')||e.labels?.[0]?.textContent||(kind==='text'?e.getAttribute('placeholder'):(e instanceof HTMLInputElement?e.getAttribute('value'):e.textContent))||'').trim(),240);
          if(!label)continue;
          const s=state(e);if(!s)continue;
          const id=ids[targets.length],t={id,kind,label,destination,submitsForm};const cost=byte(JSON.stringify(t));if(cost>budget)break;budget-=cost;
          targets.push(t);map.set(id,{e,s});
        }
        let text='',count=0;const walk=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
        while(walk.nextNode()&&count++<20000&&byte(text)<4000){const n=walk.currentNode,e=n.parentElement;if(!visible(e)||e.closest('form,input,textarea,select,button,script,style,noscript,[contenteditable]'))continue;const t=clip(n.textContent.trim(),4000-byte(text)-1);if(t)text+=t+'\\n'}
        const snapshot=\(try Self.errandJSON(snapshot));globalThis.__orbitErrand={snapshot,map,url:location.href,outline:null};
        return JSON.stringify({id:\(try Self.errandJSON(tabID)),snapshot,revision:\(revision),url:location.href,title:clip(document.title,320),text,targets});})()
        """
        guard let raw = try await errandCall(expression, revision: revision, isCurrent: isCurrent) as? String,
              raw.utf8.count <= 16_000, let data = raw.data(using: .utf8),
              let page = try? JSONDecoder().decode(BrowserAIErrandPage.self, from: data),
              page.id == tabID, page.snapshot == snapshot, page.revision == revision,
              BrowserAIErrandObservation(pages: [page]).isBounded else { throw BrowserEngineError.unsupportedOperation }
        return page
    }

    private func errandTargetCall(_ target: UUID, page: BrowserAIErrandPage, operation: String,
                                  acceptsNavigation: Bool = false,
                                  isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        let script = """
        (()=>{\(Self.errandUtilities)
        const l=globalThis.__orbitErrand;if(!l||l.snapshot!==\(try Self.errandJSON(page.snapshot))||l.url!==location.href)return false;
        const id=\(try Self.errandJSON(target)),lease=l.map.get(id);if(!lease||!eligible(lease.e)||!same(lease.e,lease.s)){clear();l.map.clear();return false}
        const e=lease.e;\(operation)
        })()
        """
        return try await errandCall(script, revision: page.revision, acceptsNavigation: acceptsNavigation, isCurrent: isCurrent) as? Bool == true
    }

    public func highlightErrandTarget(_ target: UUID, page: BrowserAIErrandPage, color: String, ink: String, provider: String, reducedMotion: Bool,
                                     isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard page.targets.contains(where: { $0.id == target }), [color, ink].allSatisfy({ $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }), provider.count <= 40 else { return false }
        return try await errandTargetCall(target, page: page, operation: """
        clear();const r=e.getBoundingClientRect(),cursor=document.createElement('div'),name=document.createElement('span');
        cursor.style.cssText='position:fixed;left:0;top:0;z-index:2147483647;pointer-events:none;color:'+\(try Self.errandJSON(color));
        cursor.innerHTML='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" style="width:22px;height:22px;filter:drop-shadow(0 1px 2px #0005)"><path fill="none" stroke="currentColor" stroke-width="1.92" stroke-linecap="round" stroke-linejoin="round" d="M6 4l11.5 7.2-5.3 1.5L9.7 18z"/><path fill="none" stroke="#FF5A5F" stroke-width="1.92" stroke-linecap="round" stroke-linejoin="round" d="M13 13.2l4.3 4.3"/></svg>';
        name.textContent=\(try Self.errandJSON(provider));name.style.cssText='position:absolute;left:18px;top:18px;font:600 11px -apple-system;padding:2px 7px;border-radius:99px;white-space:nowrap;color:'+\(try Self.errandJSON(ink))+';background:'+\(try Self.errandJSON(color));cursor.append(name);document.documentElement.append(cursor);l.cursor=cursor;
        const x=r.x+Math.min(60,r.width/2),y=r.y+14;let frames;
        if(\(reducedMotion ? "true" : "false")){cursor.style.transform='translate('+x+'px,'+y+'px)';frames=[{opacity:0},{opacity:1}]}
        else frames=Array.from({length:121},(_,i)=>{const t=i/120,p=t<.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2;return {offset:t,transform:'translate('+(420+(x-420)*p)+'px,'+(60+(y-60)*p)+'px)'}});
        const animation=cursor.animate(frames,{duration:\(reducedMotion ? 150 : 900),fill:'forwards',easing:'linear'});
        return animation.finished.then(async()=>{if(!\(reducedMotion ? "true" : "false"))await new Promise(r=>setTimeout(r,50));if(globalThis.__orbitErrand!==l||!eligible(e)||!same(e,lease.s))return false;const o=document.createElement('div');
        o.style.cssText='position:fixed;pointer-events:none;z-index:2147483646;box-sizing:border-box;background:transparent;outline:3px solid '+\(try Self.errandJSON(color))+';border-radius:'+getComputedStyle(e).borderRadius+';left:'+r.x+'px;top:'+r.y+'px;width:'+r.width+'px;height:'+r.height+'px';document.documentElement.append(o);l.outline=o;return true}).catch(()=>false);
        """, isCurrent: isCurrent)
    }

    public func executeErrandAction(_ action: BrowserAIErrandAction, page: BrowserAIErrandPage,
                                   isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard action.tabID == page.id, let target = action.targetID,
              let item = page.targets.first(where: { $0.id == target }) else { return false }
        let operation: String
        switch action {
        case .click where item.kind == .link || item.kind == .button:
            // Native navigation and popup policy remains authoritative over dispatch.
            operation = "l.map.clear();clear();e.click();return true;"
        case .type(_, _, let value) where item.kind == .text:
            guard value.count <= 2000, value.utf8.count <= 8000,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
            operation = """
            if(!(e instanceof HTMLInputElement||e instanceof HTMLTextAreaElement))return false;
            l.map.clear();clear();const proto=e instanceof HTMLInputElement?HTMLInputElement.prototype:HTMLTextAreaElement.prototype;
            Object.getOwnPropertyDescriptor(proto,'value').set.call(e,\(try Self.errandJSON(value)));e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return true;
            """
        default: return false
        }
        return try await errandTargetCall(target, page: page, operation: operation, acceptsNavigation: true, isCurrent: isCurrent)
    }

    public func clearErrandTarget(snapshot: UUID) async {
        guard let token = try? Self.errandJSON(snapshot) else { return }
        _ = try? await errandCall("(()=>{const l=globalThis.__orbitErrand;if(l?.snapshot!==\(token))return false;l.outline?.remove();l.cursor?.remove();delete globalThis.__orbitErrand;return true})()",
                                  revision: documentGeneration, isCurrent: { true })
    }
}
