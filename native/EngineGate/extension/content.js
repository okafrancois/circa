"use strict";

(() => {
  const pageURL = new URL(location.href);
  if (pageURL.protocol !== "http:" || pageURL.hostname !== "127.0.0.1" || pageURL.pathname !== "/page") return;

  const protocol = OrbitEngineGateProtocol;
  const startedAt = Date.now();
  const caseName = new URLSearchParams(location.search).get("case");
  const requestID = protocol.randomID();
  const fallbackRunID = protocol.randomID();
  const expectedTitle = document.title;
  const extensionID = typeof globalThis.chrome?.runtime?.id === "string" ? chrome.runtime.id : null;
  const results = new Map();
  const allNames = [...protocol.contentResultNames, ...protocol.workerResultNames];
  let observedWorkerRunID = null;
  let observedTabContext = null;
  let reporting = false;
  let echoUsed = false;
  const probeURL = new URL("/blocked", pageURL.origin);
  probeURL.searchParams.set("case", caseName ?? "");
  probeURL.searchParams.set("probe", requestID);
  const message = {
    kind: protocol.runKind,
    case: caseName,
    pageURL: pageURL.href,
    requestID,
    expectedTitle
  };

  function record(name, passed, detail) {
    if (!reporting && !(results.get(name)?.passed === false && passed === true)) {
      results.set(name, { name, passed: passed === true, detail });
    }
  }
  const passed = (name) => results.get(name)?.passed === true;

  function validEnvelope(reply, kind) {
    return reply?.kind === kind && reply.case === caseName && reply.requestID === requestID &&
      extensionID !== null && reply.extensionID === extensionID && typeof reply.workerRunID === "string" &&
      /^[a-f0-9-]{36}$/.test(reply.workerRunID) && Array.isArray(reply.results);
  }

  function importResults(reply, names) {
    for (const name of names) {
      const matches = reply.results.filter((result) => result?.name === name);
      const result = matches[0];
      const scalar = result?.detail === null || ["string", "boolean"].includes(typeof result?.detail) ||
        (typeof result?.detail === "number" && Number.isFinite(result.detail));
      if (matches.length !== 1 || typeof result?.passed !== "boolean" || !scalar) {
        record(name, false, "Required worker result missing, duplicated, or malformed");
      } else {
        record(name, result.passed, typeof result.detail === "string" ? protocol.errorDetail({ message: result.detail }) : result.detail);
      }
    }
  }

  try {
    if (typeof globalThis.chrome?.runtime?.onMessage?.addListener !== "function") {
      throw new Error("API unavailable: runtime.onMessage.addListener");
    }
    chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
      if (reporting || echoUsed || sender.id !== extensionID || request?.kind !== protocol.echoKind ||
          request.case !== caseName || request.requestID !== requestID ||
          typeof request.workerRunID !== "string" || !/^[a-f0-9-]{36}$/.test(request.workerRunID)) return false;
      echoUsed = true;
      void protocol.probe(probeURL.href).then((baseline) => {
        if (reporting) return;
        try {
          sendResponse({
            kind: protocol.echoReplyKind,
            case: caseName,
            requestID,
            workerRunID: request.workerRunID,
            baseline
          });
        } catch (error) {
          record("runtime.contentRoundTrip", false, protocol.errorDetail(error));
        }
      });
      return true;
    });
  } catch (error) {
    record("runtime.contentRoundTrip", false, protocol.errorDetail(error));
  }

  async function report(missingDetail = "Required test did not complete") {
    if (reporting) return;
    reporting = true;
    clearTimeout(workTimer);
    const payload = {
      kind: "extension-report",
      case: caseName,
      extensionID,
      results: allNames.map((name) => results.get(name) ?? { name, passed: false, detail: missingDetail }),
      workerRunID: observedWorkerRunID ?? fallbackRunID
    };
    if (caseName?.startsWith("chrome-native-")) payload.tabContext = observedTabContext;
    const controller = new AbortController();
    const remainingMs = Math.min(1800, protocol.contentDeadlineMs - (Date.now() - startedAt));
    const timer = setTimeout(() => controller.abort(), Math.max(1, remainingMs));
    try {
      const response = await fetch(new URL("/report", pageURL.origin), {
        method: "POST",
        mode: "same-origin",
        credentials: "omit",
        cache: "no-store",
        redirect: "error",
        referrerPolicy: "no-referrer",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
        signal: controller.signal,
        keepalive: true
      });
      if (!response.ok) throw new Error("Report endpoint rejected the report");
    } catch {
      // A missing/rejected report is a runner failure; console output is never a success signal.
      console.error("Orbit Engine Gate JSON report delivery failed");
    } finally {
      clearTimeout(timer);
    }
  }

  const workTimer = setTimeout(() => {
    void report("Content deadline exceeded before the required result completed");
  }, protocol.contentWorkDeadlineMs);

  async function run() {
    record("content.fixture", typeof caseName === "string" && caseName.length > 0 && !pageURL.username && !pageURL.password && /^[a-p]{32}$/.test(extensionID ?? ""),
      "Loopback /page requires a nonempty synthetic case and a real extension ID");
    record("content.documentIdle", document.readyState !== "loading" && window.top === window,
      document.readyState === "loading" ? "Content script ran before document_idle" : document.readyState);

    try {
      const reply = await protocol.apiCall("runtime.sendMessage", () => chrome.runtime, "sendMessage", [message], 7500);
      if (!validEnvelope(reply, protocol.replyKind)) throw new Error("Worker reply envelope is invalid");
      observedWorkerRunID = reply.workerRunID;
      if (caseName?.startsWith("chrome-native-") && reply.tabContext && typeof reply.tabContext === "object") {
        observedTabContext = Object.fromEntries(
          ["windowID", "tabID", "splitViewID", "peerTabID", "peerWindowID", "peerSplitViewID", "tabCount"]
            .map((key) => [key, Number.isInteger(reply.tabContext[key]) ? reply.tabContext[key] : null])
        );
      }
      record("runtime.workerResponse", true, "Actual worker response matches the case, request, and extension ID");
      importResults(reply, protocol.workerResultNames);
    } catch (error) {
      record("runtime.workerResponse", false, protocol.errorDetail(error));
    }
    if (reporting) return;

    const markerValue = observedWorkerRunID === null ? null : `${observedWorkerRunID}:${requestID}`;
    const markerMatches = markerValue !== null && document.documentElement?.getAttribute(protocol.markerAttribute) === markerValue;
    record("scripting.domMarker", markerMatches && passed("scripting.executeScript"), markerMatches ? "Exact worker/request marker is present in this document" : "Expected DOM marker is absent or mismatched");

    // Identical URL and uncached controls distinguish a rule block from an unavailable endpoint.
    const blocked = await protocol.probe(probeURL.href);
    if (reporting) return;
    try {
      const reply = await protocol.apiCall("runtime.sendMessage", () => chrome.runtime, "sendMessage", [{ ...message, kind: protocol.cleanupKind }], 3200);
      if (!validEnvelope(reply, protocol.cleanupReplyKind)) throw new Error("Cleanup reply envelope is invalid");
      importResults(reply, ["dnr.cleanupDynamicRule"]);
    } catch (error) {
      record("dnr.cleanupDynamicRule", false, protocol.errorDetail(error));
    }
    if (reporting) return;

    const restored = await protocol.probe(probeURL.href);
    const restoredPassed = restored.outcome === "response" && restored.status === 200 && restored.exactURL === true;
    record("dnr.restoredFetch", restoredPassed && passed("dnr.cleanupDynamicRule"), restoredPassed ? 200 : `Restored control failed: ${restored.outcome}; status ${restored.status ?? "none"}`);
    const blockPassed = blocked.outcome === "rejected" && blocked.errorName === "TypeError" &&
      ["dnr.resetDynamicRules", "dnr.baselineFetch", "dnr.updateDynamicRules", "dnr.getDynamicRules", "dnr.cleanupDynamicRule", "dnr.restoredFetch"].every(passed);
    const blockDetail = blocked.outcome === "response" ? `Block failed: HTTP ${blocked.status}` :
      blocked.outcome === "timeout" ? "Block probe timed out; timeout is not evidence of blocking" :
        blockPassed ? "Fetch rejected between HTTP 200 controls with exact rule 1001 installed" :
          `Block unproven: ${blocked.errorName}; required rule/control evidence failed`;
    record("dnr.blockedFetch", blockPassed, blockDetail);
    await report();
  }

  void run().catch((error) => {
    void report(`Content execution failed: ${protocol.errorDetail(error)}`);
  });
})();
