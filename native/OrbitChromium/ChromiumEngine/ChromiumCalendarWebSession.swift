import BrowserCore
import BrowserEngine
import Foundation

extension ChromiumBrowserEngine: BrowserCalendarWebSession {
    public func calendarAgenda(profileID: ProfileID, account: BrowserCalendarWebAccount,
                               day: Date, timeZone: TimeZone) async throws -> BrowserCalendarWebAgenda {
        try await calendarAgenda(profileID: profileID, account: account, day: day, timeZone: timeZone, origin: nil)
    }

    @_spi(Testing)
    public func calendarAgendaFixture(profileID: ProfileID, account: BrowserCalendarWebAccount,
                                      day: Date, timeZone: TimeZone, origin: URL) async throws -> BrowserCalendarWebAgenda {
        guard Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true,
              origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil,
              origin.path.isEmpty, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil else { throw BrowserCalendarWebError.invalidResponse }
        return try await calendarAgenda(profileID: profileID, account: account, day: day, timeZone: timeZone, origin: origin)
    }

    private func calendarAgenda(profileID: ProfileID, account: BrowserCalendarWebAccount,
                                day: Date, timeZone: TimeZone, origin: URL?) async throws -> BrowserCalendarWebAgenda {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyyMMdd"
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else { throw BrowserCalendarWebError.invalidResponse }
        let dates = formatter.string(from: day) + "/" + formatter.string(from: tomorrow)
        let feedURL = (origin ?? URL(string: "https://calendar.google.com")!).appendingPathComponent("calendar/u/\(account.slot)/r")
        guard !isShutDown, persistence == .persistent else { throw BrowserCalendarWebError.unavailable }
        if let after = calendarReadAfter[profileID]?[account.slot], after > Date() {
            throw BrowserCalendarWebError.throttled(after.timeIntervalSinceNow)
        }
        calendarReadAfter[profileID, default: [:]][account.slot] = Date().addingTimeInterval(65)
        let document = ChromiumCalendarDocument(feedURL: feedURL)
        let surface = makeSurface(profileID: profileID, delegate: document)
        defer { surface.dispose() }
        surface.navigate(to: feedURL)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while !document.finished && !document.failed && clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard !document.signedOut else { throw BrowserCalendarWebError.signedOut }
        guard document.finished, !document.failed, !surface.isDisposed,
              surface.navigationState.committedURL == feedURL else { throw BrowserCalendarWebError.unavailable }
        let generation = surface.documentGeneration
        let (frameOK, frameData) = await surface.devToolsCall("Page.getFrameTree")
        guard frameOK, let tree = try JSONSerialization.jsonObject(with: frameData) as? [String: Any],
              let frameTree = tree["frameTree"] as? [String: Any], let frame = frameTree["frame"] as? [String: Any],
              let frameID = frame["id"] as? String else { throw BrowserCalendarWebError.invalidResponse }
        let worldParams = try JSONSerialization.data(withJSONObject: ["frameId": frameID, "worldName": "OrbitCalendar"])
        let (worldOK, worldData) = await surface.devToolsCall("Page.createIsolatedWorld", params: String(decoding: worldParams, as: UTF8.self))
        guard worldOK, let world = try JSONSerialization.jsonObject(with: worldData) as? [String: Any],
              let context = world["executionContextId"] as? Int else { throw BrowserCalendarWebError.invalidResponse }
        let encodedURL = String(decoding: try JSONEncoder().encode(feedURL.absoluteString), as: UTF8.self)
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["dates": dates, "zone": timeZone.identifier,
            "path": "/calendar/u/\(account.slot)/htmlembed"]), as: UTF8.self)
        let expression = """
        (async () => {
          if (location.href !== \(encodedURL)) throw Error('document');
          const identity=()=>{
            const labels=[...document.querySelectorAll('a[aria-label][href^="https://accounts.google.com/"]')]
              .map(e=>e.getAttribute('aria-label'));
            const ids=[...new Set(labels.flatMap(s=>s.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/ig)||[]))];
            if(ids.length!==1)throw Error('identity'); return ids[0];
          };
          const signal=AbortSignal.timeout(10000);
          const binding=identity(), args=\(args), url=new URL(args.path,location.origin);
          url.search=new URLSearchParams({src:binding,mode:'AGENDA',dates:args.dates,ctz:args.zone,hl:'en'});
          const r=await fetch(url.href,{credentials:'same-origin',redirect:'manual',cache:'no-store',
            signal,headers:{Accept:'text/html'}});
          if(r.type==='opaqueredirect'||[401,403,404].includes(r.status))return {signedOut:true};
          if([429,503].includes(r.status))return {throttled:true,retry:r.headers.get('Retry-After')};
          if(!r.ok||r.url!==url.href||!/^text\\/html(?:;|$)/i.test(r.headers.get('Content-Type')||''))throw Error('response');
          const charset=(r.headers.get('Content-Type')||'').match(/charset=([^; ]+)/i);
          if(charset&&!/^utf-?8$/i.test(charset[1].replaceAll('"','')))throw Error('charset');
          async function bounded(response) {
            const reader=response.body.getReader(),decoder=new TextDecoder('utf-8',{fatal:true});
            let body='',size=0;
            try {while(true){const p=await reader.read();if(p.done)break;
              size+=p.value.byteLength;if(size>1048576)throw Error('size');body+=decoder.decode(p.value,{stream:true});}
              body+=decoder.decode();}finally{await reader.cancel();}
            return body;
          }
          const body=await bounded(r);
          let bootstrap=null, retry=null;
          try {
            const dayURL=new URL(location.pathname+'/day',location.origin);
            const d=await fetch(dayURL.href,{credentials:'same-origin',redirect:'manual',cache:'no-store',signal,headers:{Accept:'text/html'}});
            if([401,403].includes(d.status))return {signedOut:true};
            if([429,503].includes(d.status))retry=d.headers.get('Retry-After')||'120';
            if(d.ok && d.url===dayURL.href && /^text\\/html(?:;|$)/i.test(d.headers.get('Content-Type')||'')) {
              const html=await bounded(d);
              // DOMParser is inert; never insert nodes or execute page scripts.
              const doc=new DOMParser().parseFromString(html,'text/html');
              const nodes=doc.querySelectorAll('script#initialdata[type="application/json"]');
              if(nodes.length===1)bootstrap=JSON.stringify(JSON.parse(nodes[0].textContent));
            }
          } catch { /* Optional enrichment fails silently. */ }
          if(identity()!==binding)throw Error('identity');
          return {body,binding,bootstrap,retry};
        })()
        """
        let params = try JSONSerialization.data(withJSONObject: ["contextId": context, "expression": expression,
            "awaitPromise": true, "returnByValue": true])
        let (ok, data) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: params, as: UTF8.self), timeout: .seconds(12))
        try Task.checkCancellation()
        guard ok, !surface.isDisposed, surface.documentGeneration == generation,
              surface.navigationState.committedURL == feedURL,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["exceptionDetails"] == nil,
              let result = object["result"] as? [String: Any], let value = result["value"] as? [String: Any] else {
            throw BrowserCalendarWebError.invalidResponse
        }
        if value["signedOut"] as? Bool == true { throw BrowserCalendarWebError.signedOut }
        if value["throttled"] as? Bool == true {
            let raw = value["retry"] as? String ?? ""
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let delay = Double(raw) ?? formatter.date(from: raw)?.timeIntervalSinceNow ?? 120
            let bounded = max(60, min(86400, delay))
            calendarReadAfter[profileID, default: [:]][account.slot] = Date().addingTimeInterval(bounded)
            throw BrowserCalendarWebError.throttled(bounded)
        }
        guard let body = value["body"] as? String, let binding = value["binding"] as? String else { throw BrowserCalendarWebError.invalidResponse }
        if let retry = value["retry"] as? String {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let delay = Double(retry) ?? formatter.date(from: retry)?.timeIntervalSinceNow ?? 120
            calendarReadAfter[profileID, default: [:]][account.slot] = Date().addingTimeInterval(max(120, min(86400, delay)))
        }
        let agenda = try BrowserCalendarWebAgenda.decode(html: body, account: account, binding: binding,
                                                         day: day, timeZone: timeZone, fetchedAt: Date())
        guard let bootstrap = value["bootstrap"] as? String else { return agenda }
        return BrowserCalendarBootstrap.enrich(agenda, json: Data(bootstrap.utf8))
    }
}

@MainActor
private final class ChromiumCalendarDocument: BrowserEngineSurfaceDelegate {
    let feedURL: URL
    var finished = false
    var failed = false
    var signedOut = false
    init(feedURL: URL) { self.feedURL = feedURL }
    func surfaceDidStartNavigation(_ surface: ChromiumSurface) { finished = false }
    func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFinishNavigation(_ surface: ChromiumSurface) { finished = true }
    func surfaceDidFailNavigation(_ surface: ChromiumSurface) { failed = true }
    func surfaceDidRequestClose(_ surface: ChromiumSurface) { failed = true }
    func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        let allowed = action.url == feedURL && action.httpMethod != "POST"
        if !allowed { failed = true; signedOut = action.url?.host == "accounts.google.com" }
        decision.decide(allowed ? .allow : .cancel)
    }
    func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
    func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel(); failed = true }
    func surface(_ surface: ChromiumSurface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision { .deny }
}
