import BrowserCore
import BrowserEngine
import Foundation

/// Chrome keeps its own history per profile (the History database, and the visited-link,
/// top-site, favicon, omnibox-shortcut and predictor stores that follow its deletions). When the
/// shell deletes history, the same visits leave Chrome's history here, through the history page's
/// own handler running in a windowless chrome://history page of that profile (which binds it to
/// that profile and no other): it lists the matching visits, removes them and lists again;
/// leftovers fail the call. Chrome removes a URL's visits per local day, so a single visit, an
/// interval or a period also removes that URL's other visits of the same day in Chrome's history
/// only; the shell's own history keeps them.
///
/// The settings page's clear-browsing-data handler is not used for history: after a history
/// removal it notifies the browser window of the page's tab, which a windowless page does not
/// have, and the engine stops on a CHECK.
extension ChromiumBrowserEngine: BrowserEngineHistoryAccess {
    /// What the last removal saw (diagnostics for the synthetic probe; counts only, no URLs).
    public static var lastHistoryRemovalReport: [String: Any] = [:]

    public func removeEngineHistory(_ removal: BrowserEngineHistoryRemoval, profileID: ProfileID) async throws {
        // Off-the-record and windowed (non-Chrome) runtimes keep no history of their own.
        guard persistence == .persistent, surfaceMode == .hosted else { return }
        guard let script = Self.historyRemovalScript(removal) else { throw BrowserEngineHistoryError.removalIncomplete }
        Self.lastHistoryRemovalReport = ["stage": "page"]
        do {
            try await withHiddenSiteDataPage(URL(string: "chrome://history/")!, profileID: profileID) { surface in
                Self.lastHistoryRemovalReport = ["stage": "evaluate"]
                let result = try await siteDataCommand("Runtime.evaluate", parameters: [
                    "expression": script, "returnByValue": true, "awaitPromise": true
                ], surface: surface, timeout: .seconds(90))
                // A thrown error comes back as the result too (an empty object by value).
                if let details = result["exceptionDetails"] as? [String: Any] {
                    let description = (details["exception"] as? [String: Any])?["description"] as? String
                    Self.lastHistoryRemovalReport = ["exception": description ?? details["text"] as? String ?? "unknown"]
                    throw BrowserEngineHistoryError.removalIncomplete
                }
                let value = (result["result"] as? [String: Any])?["value"] as? [String: Any]
                Self.lastHistoryRemovalReport = value ?? ["value": "missing"]
                guard let value, (value["remaining"] as? NSNumber)?.intValue == 0 else {
                    throw BrowserEngineHistoryError.removalIncomplete
                }
            }
        } catch is BrowserSiteDataError {
            throw BrowserEngineHistoryError.removalIncomplete
        }
    }

    static func historyRemovalScript(_ removal: BrowserEngineHistoryRemoval) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: removal.historyPageFilter(), options: [.sortedKeys])
        else { return nil }
        return "(\(historyRemovalFunction))(\(String(decoding: data, as: UTF8.self)))"
    }

    /// Binds its own handler of the history page (replacing the page's, so the page's own queries
    /// never cancel these), lists matching visits newest first, removes them in one request and
    /// lists again. A removal Chrome refused (another deletion in progress) is retried.
    static let historyRemovalFunction = """
        async (spec) => {
          if (location.protocol !== 'chrome:' || location.host !== 'history') throw Error('page');
          await customElements.whenDefined('history-app');
          await new Promise(resolve => setTimeout(resolve, 50));
          const m = await import('chrome://resources/cr_components/history/history.mojom-webui.js');
          const handler = m.PageHandler.getRemote();
          const router = new m.PageCallbackRouter();
          handler.setPage(router.$.bindNewPipeAndPassRemote());
          const canonical = (u) => { try { return new URL(u).href; } catch (e) { return u; } };
          const hostOf = (u) => {
            try { return new URL(u).hostname.toLowerCase().replace(/^\\[|\\]$/g, ''); } catch (e) { return ''; }
          };
          const target = spec.url ? canonical(spec.url) : null;
          const matchesURL = (u) => spec.kind === 'host' ? hostOf(u) === spec.host
            : (spec.kind === 'url' || spec.kind === 'visit') ? canonical(u) === target : true;
          const matchesTime = (t) => spec.kind === 'interval' ? (t >= spec.begin && t < spec.end)
            : spec.kind === 'since' ? t >= spec.begin
            : spec.kind === 'visit' ? Math.abs(t - spec.at) <= spec.tolerance : true;
          const collect = async () => {
            const found = [];
            let reply = await handler.queryHistory('', 150, spec.begin ?? null, true, true, []);
            for (let page = 0; page < 10000; page++) {
              const result = reply.results;
              if (!result || !result.info) throw Error('cancelled');
              for (const entry of result.value) {
                for (const [url, stamps] of Object.entries(entry.allTimestamps)) {
                  if (!matchesURL(url)) continue;
                  const hits = stamps.filter(matchesTime);
                  if (hits.length) found.push({url, timestamps: hits});
                }
              }
              // A listing bounded by a start never reports itself finished: it goes on with
              // empty pages, so an empty page or an entry older than the start ends it too.
              if (result.info.finished || !result.value.length) return found;
              if (spec.begin != null && result.value.some(entry => entry.time < spec.begin)) return found;
              reply = await handler.queryHistoryContinuation();
            }
            throw Error('unbounded');
          };
          let removed = 0;
          const seen = [];
          for (let attempt = 0; attempt < 4; attempt++) {
            const matches = await collect();
            seen.push(matches.length);
            if (!matches.length) return {removed, remaining: 0, seen};
            if (attempt === 3) return {removed, remaining: matches.length, seen};
            if (attempt > 0) await new Promise(resolve => setTimeout(resolve, 250 * attempt));
            await handler.removeVisits(matches);
            removed += matches.length;
          }
        }
        """
}
