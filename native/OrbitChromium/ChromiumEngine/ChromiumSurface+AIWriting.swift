import BrowserEngine
import Foundation

extension ChromiumSurface: BrowserAIWriting {
    private func writingCall(_ expression: String, revision: UInt64,
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
        guard let node = tree["frameTree"] as? [String: Any], let frame = node["frame"] as? [String: Any],
              let id = frame["id"] as? String else { throw BrowserEngineError.unsupportedOperation }
        let world = try await call("Page.createIsolatedWorld", ["frameId": id, "worldName": "OrbitWritingData"])
        guard let context = world["executionContextId"] as? Int else { throw BrowserEngineError.unsupportedOperation }
        let result = try await call("Runtime.evaluate", ["contextId": context, "expression": expression, "returnByValue": true])
        return (result["result"] as? [String: Any])?["value"]
    }

    /// The lease keeps the original element/range in the isolated world, never in page attributes.
    private static let writingLease = #"""
    (()=>{
      const e=document.activeElement;
      if(!e||e.closest('[hidden],[inert],[aria-hidden="true"],[autocomplete="current-password"],[autocomplete="new-password"]'))return null;
      const input=e instanceof HTMLInputElement,area=e instanceof HTMLTextAreaElement;
      if(input&&!['text','search','url','email','tel'].includes(e.type))return null;
      if(!(input||area||e.isContentEditable)||e.disabled||e.readOnly)return null;
      const style=getComputedStyle(e);if(style.display==='none'||style.visibility!=='visible'||(style.webkitTextSecurity&&style.webkitTextSecurity!=='none')||!e.getClientRects().length)return null;
      let start,end,range=null,text,full;
      if(input||area){start=e.selectionStart;end=e.selectionEnd;if(start==null||end==null||start===end)return null;full=e.value;text=full.slice(start,end)}
      else {const s=getSelection();if(!s||s.isCollapsed||s.rangeCount!==1)return null;range=s.getRangeAt(0);if(!e.contains(range.commonAncestorContainer))return null;full=e.innerHTML;text=range.toString()}
      if(!text.trim()||text.length>12000||full.length>100000)return null;
      const old=globalThis.__orbitWritingLease;
      const same=old&&old.e===e&&old.full===full&&old.text===text&&(range?old.range&&old.range.startContainer===range.startContainer&&old.range.startOffset===range.startOffset&&old.range.endContainer===range.endContainer&&old.range.endOffset===range.endOffset:old.start===start&&old.end===end);
      const lease=same?old:{e,full,text,start,end,range:range?.cloneRange(),token:String(globalThis.__orbitWritingSequence=(globalThis.__orbitWritingSequence||0)+1)};
      globalThis.__orbitWritingLease=lease;
      const r=range?.getBoundingClientRect()||e.getBoundingClientRect();
      if(r.width<=0||r.height<=0||r.bottom<0||r.top>innerHeight)return null;
      return {token:lease.token,text,x:r.x,y:r.y,width:r.width,height:r.height};
    })()
    """#

    public func writingSelection(revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> BrowserAIWritingSelection? {
        guard let result = try await writingCall(Self.writingLease, revision: revision, isCurrent: isCurrent) as? [String: Any],
              let token = result["token"] as? String, let text = result["text"] as? String,
              let x = result["x"] as? Double, let y = result["y"] as? Double,
              let width = result["width"] as? Double, let height = result["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite) else { return nil }
        return .init(token: token, text: text, bounds: CGRect(x: x * pageZoom, y: y * pageZoom,
                                                            width: width * pageZoom, height: height * pageZoom))
    }

    public func applyWriting(_ text: String, selection: BrowserAIWritingSelection, insertBelow: Bool,
                             revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard !text.isEmpty, text.count <= 12000 else { return false }
        let token = String(decoding: try JSONEncoder().encode(selection.token), as: UTF8.self)
        let value = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        let script = """
        (()=>{const current=\(Self.writingLease);if(!current||current.token!==\(token))return false;
        const lease=globalThis.__orbitWritingLease,e=lease.e,below=\(insertBelow ? "true" : "false");
        let value=\(value);e.focus({preventScroll:true});
        if(lease.range){const r=lease.range.cloneRange();if(below){r.collapse(false);value='\\n'+value}const s=getSelection();s.removeAllRanges();s.addRange(r)}
        else{e.setSelectionRange(below?lease.end:lease.start,lease.end);if(below)value=(e instanceof HTMLInputElement?' ':'\\n')+value}
        const applied=document.execCommand('insertText',false,value);delete globalThis.__orbitWritingLease;return applied})()
        """
        return try await writingCall(script, revision: revision, isCurrent: isCurrent) as? Bool == true
    }
}
