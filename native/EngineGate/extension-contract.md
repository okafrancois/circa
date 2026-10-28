# Synthetic MV3 CEF runtime contract

This unpacked extension is a runtime probe, not an implementation of extension APIs. Its source and Node syntax checks establish no CEF runtime support, product readiness, engine selection, Chrome Web Store installation, or general extension compatibility. The host and runner own actual execution and evidence.

## Files and permissions

Load the absolute directory `native/EngineGate/extension/` as an unpacked extension. `manifest.json` declares MV3, classic service worker `worker.js`, and `protocol.js` followed by `content.js` at `document_idle`, main frame only.

Exact required permissions:

```json
{
  "permissions": ["storage", "tabs", "scripting", "declarativeNetRequest"],
  "host_permissions": ["http://127.0.0.1/*"]
}
```

The host match pattern covers dynamic ports. The extension has no remote host access, optional grants, action, popup, options page, native messaging, externally connectable page, or page-native bridge. `permissions.contains` is included as a required probe of the permissions above; unavailable means failed. It never requests a permission or calls `tabs.create`, `tabs.update`, or any window creation/activation API.

## Host responsibilities

Use an isolated synthetic request context and the selected host visibility policy. Do not load this fixture into a personal profile. Run one case at a time per extension/context: dynamic rule **1001** and the synthetic storage key are intentionally shared. Separate contexts can run independently. The extension ID is the real `chrome.runtime.id`; no manifest key fixes an artificial ID. Record the actual loaded ID and compare every report with it.

Bind an HTTP server to `127.0.0.1` on a dynamically assigned port before navigation. Keep it alive through report acceptance. Never use port 4318 or the user's tracking origin. The server supplies:

| Route | Required behavior |
| --- | --- |
| `GET /page?case=<synthetic-case>` | HTTP 200 HTML with a server-assigned, stable synthetic document title and any synthetic test inputs. No script bridge is needed. Do not redirect or mutate the title during the test. |
| `GET /blocked?case=<case>&probe=<request-uuid>` | HTTP **200** without redirect, `Cache-Control: no-store`. It must succeed when the extension's rule is absent. Do not implement blocking in the server. |
| `POST /report` | Accept `application/json`, validate and preserve the report, then return a 2xx response promptly. A missing report, invalid schema, unexpected extension/case, or any failed result fails the case. |

Use only synthetic, nonsecret case names, titles, and input values. A case must be a nonempty string; the exact decoded `URLSearchParams(location.search).get('case')` is reported without renaming. `case: null` is allowed only in a failure report for a malformed fixture URL. Content scripts ignore routes other than `/page`; the manifest grants only the loopback origin.

The host must not emulate APIs, insert the marker itself, spoof worker replies, intercept `/blocked` to manufacture a network error, or infer success from a loaded worker. A native implementation error is a failure even if another operation succeeds.

## Runtime sequence and evidence

1. The content script records its main-frame/document-idle state and sends `orbit-engine-gate-run` through the actual `runtime.sendMessage` API. The request includes the synthetic title, exact fixture URL, case, and random request UUID.
2. The worker validates real sender extension/tab/window/frame metadata. In parallel it writes and reads `storage.local`, calls `tabs.get`, calls `tabs.query({windowId: sender.tab.windowId})`, injects through `scripting.executeScript`, and checks declared permissions. `tabs.get` must return the sender ID, window ID, fixture URL, and server-assigned title. Query results must contain that sender exactly once. Native-window cases additionally validate the exact synthetic peer URL/title and report only the allowlisted numeric identity metadata below. A missing window ID fails `runtime.sender`, `tabs.get` and `tabs.query`, but does not suppress probes that need only the validated page, tab and frame. This preserves diagnostic separation without weakening the full case verdict.
3. The worker removes stale rule 1001, then uses `tabs.sendMessage` targeted to the sender frame. The content reply includes a real successful baseline fetch of `/blocked`. The content script receives no page-native message or injected success value.
4. The worker adds the rule below and reads it back through `getDynamicRules`. Only those API results, not a fixture constant, determine their corresponding statuses.
5. After the worker's response, the content script checks the exact DOM marker and fetches the identical `/blocked` URL again. A resolved response, including 4xx/5xx, is a failed block. An abort/timeout is also a failed block.
6. The content script requests cleanup through `runtime.sendMessage`. The worker removes rule 1001 and verifies its absence. The content script fetches the same URL a third time; it must return HTTP 200. The block result passes only for a non-timeout `TypeError` rejection between successful HTTP 200 controls, with successful rule installation/readback/removal. The runner must also corroborate server request counts: two successful GETs for that probe, with no delivered middle request. Fetch alone cannot expose Chromium's internal network error code.
7. The content script posts one JSON report to the same origin's `/report`. It reports failures and incomplete tests too. There is no aggregate success shortcut or skipped-success status.

The dynamic rule is constructed from the validated sender's actual origin:

```json
{
  "id": 1001,
  "priority": 1,
  "action": {"type": "block"},
  "condition": {
    "urlFilter": "|http://127.0.0.1:<actual-port>/blocked",
    "requestDomains": ["127.0.0.1"],
    "resourceTypes": ["xmlhttprequest"]
  }
}
```

This is a dynamic rule with a known ID, not a packaged static ruleset. It uses `urlFilter`, never `regexFilter`. `/page` and `/report` are outside its URL prefix. The marker attribute is `data-orbit-engine-gate-marker` on `document.documentElement`, with value `<workerRunID>:<requestID>`. Injection uses `world: "ISOLATED"` and the exact sender `frameId`. No page JavaScript is trusted to create or confirm it.

Storage key: `orbit.engineGate.syntheticSentinel`. Value: `orbit-engine-gate-storage-v1:<workerRunID>:<requestID>`. Readback must equal the just-written value; a previous run's value cannot pass. In `chrome-profiles` cases, the page URL also supplies `phase=initial|restore`. Before writing, the initial phase requires both the sentinel and `orbit.engineGate.extensionPersistence` to be absent. It writes the current case into that persistence key. The restore phase requires that key to equal its own case before replacing the transient sentinel. Both keys must then read back correctly. A marker inherited from the other profile fails. The runner controls a full host restart between these phases against the same synthetic root; this profile mode does not assert worker suspension and restart within a running browser.

In `chrome-workers-a`, the worker also requires empty initial storage, then writes the persistence marker `chrome-workers`. The runner withholds the `chrome-workers-b` document until at least 40 seconds after the first complete report. That case requires the earlier marker before writing. Both complete 19-result reports must pass and contain disjoint real worker evaluation IDs. The host remains running throughout. This establishes reevaluation after an idle interval with persistent extension storage; the exact termination reason is not instrumented.

## JSON report schema

```ts
type ExtensionReport = {
  kind: "extension-report";
  case: string | null;
  extensionID: string | null;
  results: Array<{
    name: string;
    passed: boolean;
    detail: string | number | boolean | null;
  }>;
  workerRunID: string;
  // Required only for chrome-native-* cases; null means missing evidence.
  tabContext?: {
    windowID: number | null;
    tabID: number | null;
    splitViewID: number | null;
    peerTabID: number | null;
    peerWindowID: number | null;
    peerSplitViewID: number | null;
    tabCount: number;
  } | null;
};
```

`extensionID` is the actual runtime ID, or `null` on an identity failure. `workerRunID` is a random UUID generated once per actual worker evaluation, so a surviving worker can report the same ID across cases. The report uses the worker ID only after validating the run response envelope. If the worker never replies or replies incorrectly, the reporter uses a separate random fallback UUID and `runtime.workerResponse` is false: that fallback is never evidence that a worker ran. Case/request/extension IDs are checked on run and cleanup replies. Cleanup may evaluate a new worker; it does not rewrite the reported test-run ID.

Native case A must initially find one unsplit tab. Case B must find exactly two distinct synthetic tabs in that same window. For ordinary tabs both split IDs must be `-1`; for Split both queried tabs must have one equal nonnegative `splitViewId`. The runner also compares B's peer tab/window IDs with A's earlier report, independently of the passed booleans. Other schemes, private data and arbitrary tab metadata never enter the report. These cases retain exactly the same 19 required result names.

The report contains exactly one entry for each of the following **19** names, in this order. The runner should require this complete set and reject duplicates or unknown names:

```text
content.fixture
content.documentIdle
runtime.workerResponse
scripting.domMarker
dnr.blockedFetch
dnr.cleanupDynamicRule
dnr.restoredFetch
runtime.sender
runtime.contentRoundTrip
storage.local.set
storage.local.get
tabs.get
tabs.query
scripting.executeScript
dnr.resetDynamicRules
dnr.baselineFetch
dnr.updateDynamicRules
dnr.getDynamicRules
permissions.contains
```

`detail` contains only a bounded error description, a fixed diagnostic, a ready-state string, or an HTTP status number. No tab enumeration, title, input, storage payload, cookie, authentication value, or personal navigation content is serialized. API `runtime.lastError`, thrown exceptions, missing methods, bad readbacks, invalid replies, and deadlines become `passed: false`. A recorded content-side failure cannot be overwritten by a later passing worker result. API error descriptions preserve their failure text while redacting URLs/absolute user or temporary paths and control characters, capped at 240 characters. The case and extension/worker identifiers are separate synthetic correlation fields.

## Deadlines and failure limits

- Individual callback-based API calls: **1,200 ms**, except content-to-worker run messaging (**7,500 ms**) and cleanup messaging (**3,200 ms**).
- Each network probe: **900 ms**, with `AbortController`, no cache, no credentials, no redirects.
- Worker test run: **6,500 ms**; worker cleanup: **2,800 ms**. Every missing worker result becomes a failure when its deadline expires.
- Content work: **13,000 ms** from script start. Missing results become failures and the report is attempted even if an API hangs.
- Report delivery: at most **1,800 ms**, also capped by the remaining **15,000 ms** content budget. No retry or infinite timer exists.

These are JavaScript execution deadlines, not a claim that a blocked browser main thread can run its timers on time. The runner owns an independent wall-clock timeout and treats silence/crashes/rejected reports as failure. If content-script injection itself fails, no content reporter exists; the runner must fail the missing report rather than synthesizing success. If `/report` is unreachable, the extension cannot report its own failed transport through that endpoint; a fixed console error is diagnostic only.

Native API calls cannot be canceled by a JavaScript timeout. A late native mutation is possible on a failing implementation. After a failed/timed-out case, the host must finish disposing that synthetic context before reusing its rule namespace; do not overlap a new case with unresolved native work. Normal cleanup removes only rule 1001, leaving all other rule IDs untouched. No content-script test creates, navigates, activates, or closes a tab/window; lifecycle tests belong to the host.

## Verification and provenance

This lot is limited to new extension files and this contract. Verification is Node syntax/JSON inspection only; no browser, CEF, Electron, GUI, or native runtime test is part of this fixture delivery.

Delivery checks passed with Node **v26.8.1**: all three JavaScript syntax checks, manifest JSON parsing, exact permission/script declarations and referenced files, and a static comparison of all 19 unique result names against this contract. These checks did not evaluate the extension scripts or emulate any Chrome API.

From the repository root:

```sh
node --check native/EngineGate/extension/protocol.js
node --check native/EngineGate/extension/worker.js
node --check native/EngineGate/extension/content.js
node -e 'JSON.parse(require("node:fs").readFileSync("native/EngineGate/extension/manifest.json", "utf8"))'
```

Reconstruction choices: test names, synthetic sentinel/marker, known rule ID, finite deadlines, callback API error handling, and the before/block/after controls. API expectations follow primary documentation: [message passing](https://developer.chrome.com/docs/extensions/develop/concepts/messaging), [scripting](https://developer.chrome.com/docs/extensions/reference/api/scripting), [declarativeNetRequest](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest), and [permissions](https://developer.chrome.com/docs/extensions/reference/api/permissions). Documentation is not runtime evidence. Prior build provenance and the unresolved engine gate remain in [the compile laboratory](../../docs/native-port/cef-compile-lab-2026-10-25.md) and [the Chromium gate](../../docs/native-port/chromium-engine-gate-2026-10-25.md).
