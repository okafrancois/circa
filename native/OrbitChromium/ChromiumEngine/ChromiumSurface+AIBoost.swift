import Foundation
import AppKit
import BrowserEngine

extension ChromiumSurface: BrowserAIBoostPreview {
    private func boostCall(_ expression: String, revision: UInt64,
                           isCurrent: @escaping @MainActor () -> Bool) async throws -> Any? {
        func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            guard isCurrent(), documentGeneration == revision, !isDisposed else { throw BrowserEngineError.documentChanged }
            let data = try JSONSerialization.data(withJSONObject: params)
            let (ok, reply) = await devToolsCall(method, params: String(decoding: data, as: UTF8.self))
            guard ok, isCurrent(), documentGeneration == revision, !isDisposed,
                  let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { throw BrowserEngineError.documentChanged }
            return result
        }
        let tree = try await call("Page.getFrameTree")
        guard let node = tree["frameTree"] as? [String: Any], let frame = node["frame"] as? [String: Any], let id = frame["id"] as? String else { throw BrowserEngineError.unsupportedOperation }
        let world = try await call("Page.createIsolatedWorld", ["frameId": id, "worldName": "OrbitBoostDraft"])
        guard let context = world["executionContextId"] as? Int else { throw BrowserEngineError.unsupportedOperation }
        let result = try await call("Runtime.evaluate", ["contextId": context, "expression": expression, "returnByValue": true, "awaitPromise": true])
        return (result["result"] as? [String: Any])?["value"]
    }

    public func readBoostStructure(revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> String {
        let script = #"""
        (()=>{const out=[];let bytes=0,count=0;for(const e of document.querySelectorAll('body *')){if(count++>10000||out.length>=160)break;if(e.closest('form,input,textarea,select,button,script,style,noscript,[hidden],[inert],[aria-hidden="true"],[contenteditable]'))continue;let hidden=false;for(let a=e;a;a=a.parentElement){const s=getComputedStyle(a);if(s.display==='none'||s.visibility!=='visible'||Number(s.opacity)===0||s.contentVisibility==='hidden'||(s.webkitTextSecurity&&s.webkitTextSecurity!=='none')){hidden=true;break}}const rect=e.getBoundingClientRect();if(hidden||!e.getClientRects().length||rect.width<=0||rect.height<=0||rect.bottom<=0||rect.top>=innerHeight||rect.right<=0||rect.left>=innerWidth)continue;const safe=s=>/^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$/.test(s);const row={tag:e.localName,id:safe(e.id)?e.id:'',classes:[...e.classList].filter(safe).slice(0,6),role:['main','navigation','complementary','heading','article'].includes(e.role)?e.role:''};const text=[...e.childNodes].filter(n=>n.nodeType===3).map(n=>n.textContent.trim()).join(' ').slice(0,100);row.text=text;const line=JSON.stringify(row);const size=new TextEncoder().encode(line).length;if(bytes+size>16000)break;bytes+=size;out.push(line)}return out.join('\n')})()
        """#
        guard let text = try await boostCall(script, revision: revision, isCurrent: isCurrent) as? String else { throw BrowserEngineError.unsupportedOperation }
        return text
    }

    public func previewBoostCSS(_ css: String, lease: UUID, revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard !css.isEmpty, css.count <= 12000, css.utf8.count <= 24000 else { return false }
        let source = String(decoding: try JSONEncoder().encode(css), as: UTF8.self)
        let token = String(decoding: try JSONEncoder().encode(lease.uuidString), as: UTF8.self)
        let reduced = OrbitBoostReducedMotion()
        let script = """
        (async()=>{const source=\(source),token=\(token);const clean=source.replace(/\\/\\*[\\s\\S]*?\\*\\//g,' ');
        if(/[^a-zA-Z0-9_#.,:;{}!%*+>~\\[\\] =\\-\\n\\r\\t]/.test(clean))return false;
        const allowed=new Set(['display','visibility','opacity','color','background-color','width','min-width','max-width','height','min-height','max-height','margin','margin-top','margin-right','margin-bottom','margin-left','padding','padding-top','padding-right','padding-bottom','padding-left','font-size','font-weight','line-height','text-align','border-radius','gap','grid-template-columns','flex-direction','justify-content','align-items']);
        const comments=source.match(/\\/\\*[\\s\\S]*?\\*\\//g)||[];if(comments.some(c=>/[#@]\\s*source(?:Mapping)?URL\\s*=/i.test(c)))return false;
        const sheet=new CSSStyleSheet();try{sheet.replaceSync(source)}catch{return false}if(!sheet.cssRules.length||sheet.cssRules.length>80)return false;
        const blocks=clean.match(/[^{}]+\\{[^{}]*\\}/g);if(!blocks||blocks.join('').replace(/\\s/g,'')!==clean.replace(/\\s/g,'')||blocks.length!==sheet.cssRules.length)return false;
        for(let i=0;i<sheet.cssRules.length;i++){const r=sheet.cssRules[i];if(!(r instanceof CSSStyleRule)||!r.style.length)return false;const body=blocks[i].slice(blocks[i].indexOf('{')+1,-1);const declarations=body.split(';').filter(x=>x.trim());for(const declaration of declarations){const colon=declaration.indexOf(':');if(colon<1)return false;const property=declaration.slice(0,colon).trim().toLowerCase(),value=declaration.slice(colon+1).trim().replace(/\\s*!important\\s*$/i,'');if(!allowed.has(property)||!/^[a-zA-Z0-9#.,% !-]+$/.test(value)||!CSS.supports(property,value)||!r.style.getPropertyValue(property))return false}try{document.querySelector(r.selectorText)}catch{return false}}
        const old=globalThis.__orbitBoostDraft;if(old){old.animations?.forEach(a=>a.cancel());document.adoptedStyleSheets=document.adoptedStyleSheets.filter(s=>s!==old.sheet)}
        const elements=[],walker=document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT);while(walker.nextNode()&&elements.length<1000)elements.push(walker.currentNode);
        const before=elements.map(e=>({e,r:e.getBoundingClientRect(),display:getComputedStyle(e).display,w:getComputedStyle(e).width,h:getComputedStyle(e).height}));
        document.adoptedStyleSheets=[...document.adoptedStyleSheets,sheet];
        const hidden=before.filter(x=>x.display!=='none'&&getComputedStyle(x.e).display==='none');
        document.adoptedStyleSheets=document.adoptedStyleSheets.filter(s=>s!==sheet);
        const lease={token,sheet,animations:[]};globalThis.__orbitBoostDraft=lease;
        if(!\(reduced ? "true" : "false")){lease.animations=hidden.map(x=>x.e.animate([{opacity:getComputedStyle(x.e).opacity},{opacity:0}],{duration:200,easing:'cubic-bezier(.333333333,.666666667,.666666667,1)',fill:'forwards'}));await Promise.all(lease.animations.map(a=>a.finished.catch(()=>{})))}
        if(globalThis.__orbitBoostDraft!==lease)return false;
        lease.animations.forEach(a=>a.cancel());lease.animations=[];
        document.adoptedStyleSheets=[...document.adoptedStyleSheets,sheet];
        if(!\(reduced ? "true" : "false")){for(const x of before){const r=x.e.getBoundingClientRect();if(!r.width||!r.height||hidden.includes(x))continue;if(Math.abs(x.r.width-r.width)<.5&&Math.abs(x.r.height-r.height)<.5)continue;const a=x.e.animate([{width:x.w,height:x.h},{width:getComputedStyle(x.e).width,height:getComputedStyle(x.e).height}],{duration:400,easing:'cubic-bezier(.19,1,.22,1)'});lease.animations.push(a)}}
        await Promise.all(lease.animations.map(a=>a.finished.catch(()=>{})));return globalThis.__orbitBoostDraft===lease})()
        """
        return try await boostCall(script, revision: revision, isCurrent: isCurrent) as? Bool == true
    }

    public func clearBoostPreview(lease: UUID, revision: UInt64) async {
        let token = lease.uuidString
        _ = try? await boostCall("(()=>{const p=globalThis.__orbitBoostDraft;if(p&&p.token==='\(token)'){p.animations?.forEach(a=>a.cancel());document.adoptedStyleSheets=document.adoptedStyleSheets.filter(s=>s!==p.sheet);delete globalThis.__orbitBoostDraft}return true})()", revision: revision, isCurrent: { true })
    }
}

@MainActor private func OrbitBoostReducedMotion() -> Bool {
    ProcessInfo.processInfo.arguments.contains("--reduce-motion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}
