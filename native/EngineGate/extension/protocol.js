"use strict";

(() => {
  const workerResultNames = Object.freeze([
    "runtime.sender",
    "runtime.contentRoundTrip",
    "storage.local.set",
    "storage.local.get",
    "tabs.get",
    "tabs.query",
    "scripting.executeScript",
    "dnr.resetDynamicRules",
    "dnr.baselineFetch",
    "dnr.updateDynamicRules",
    "dnr.getDynamicRules",
    "permissions.contains"
  ]);
  const contentResultNames = Object.freeze([
    "content.fixture",
    "content.documentIdle",
    "runtime.workerResponse",
    "scripting.domMarker",
    "dnr.blockedFetch",
    "dnr.cleanupDynamicRule",
    "dnr.restoredFetch"
  ]);

  function errorDetail(error) {
    const message = typeof error?.message === "string" ? error.message : "Unknown error";
    return message
      .replace(/(?:https?|file|chrome|chrome-extension):\/\/[^\s"'<>]+/gi, "[redacted-url]")
      .replace(/\/(?:Users|home|private|var|tmp|Volumes)\/[^\s"'<>]+/g, "[redacted-path]")
      .replace(/[\u0000-\u001f\u007f]/g, " ")
      .slice(0, 240);
  }

  function randomID() {
    return crypto.randomUUID();
  }

  function apiCall(apiName, receiver, method, args, timeoutMs = 1200) {
    return new Promise((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => finish(new Error(`API deadline exceeded: ${apiName}`)), timeoutMs);
      function finish(error, value) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (error) reject(error);
        else resolve(value);
      }
      try {
        const owner = receiver();
        if (typeof owner?.[method] !== "function") {
          throw new Error(`API unavailable: ${apiName}`);
        }
        owner[method](...args, (value) => {
          // Read lastError even if the callback arrives after its deadline.
          try {
            const lastError = globalThis.chrome?.runtime?.lastError;
            finish(lastError ? new Error(`API error (${apiName}): ${lastError.message}`) : null, value);
          } catch (error) {
            finish(error);
          }
        });
      } catch (error) {
        finish(error);
      }
    });
  }

  async function probe(url, timeoutMs = 900) {
    const controller = new AbortController();
    let expired = false;
    const timer = setTimeout(() => {
      expired = true;
      controller.abort();
    }, timeoutMs);
    try {
      const response = await fetch(url, {
        method: "GET",
        mode: "same-origin",
        credentials: "omit",
        cache: "no-store",
        redirect: "error",
        referrerPolicy: "no-referrer",
        signal: controller.signal
      });
      return { outcome: "response", status: response.status, exactURL: response.url === url };
    } catch (error) {
      return {
        outcome: expired ? "timeout" : "rejected",
        errorName: typeof error?.name === "string" ? error.name : "Error",
        detail: errorDetail(error)
      };
    } finally {
      clearTimeout(timer);
    }
  }

  Object.defineProperty(globalThis, "OrbitEngineGateProtocol", {
    value: Object.freeze({
      workerResultNames,
      contentResultNames,
      errorDetail,
      randomID,
      apiCall,
      probe,
      runKind: "orbit-engine-gate-run",
      replyKind: "orbit-engine-gate-reply",
      echoKind: "orbit-engine-gate-echo",
      echoReplyKind: "orbit-engine-gate-echo-reply",
      cleanupKind: "orbit-engine-gate-cleanup",
      cleanupReplyKind: "orbit-engine-gate-cleanup-reply",
      markerAttribute: "data-orbit-engine-gate-marker",
      storageKey: "orbit.engineGate.syntheticSentinel",
      sentinel: "orbit-engine-gate-storage-v1",
      ruleID: 1001,
      workerDeadlineMs: 6500,
      cleanupDeadlineMs: 2800,
      contentWorkDeadlineMs: 13000,
      contentDeadlineMs: 15000
    })
  });
})();
