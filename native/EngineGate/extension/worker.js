"use strict";

importScripts("protocol.js");

const protocol = OrbitEngineGateProtocol;
// A fresh ID identifies this actual service-worker evaluation, not a test fixture response.
const workerRunID = protocol.randomID();

function validPageSender(message, sender) {
  try {
    const url = new URL(sender.url);
    return sender.id === chrome.runtime.id &&
      url.protocol === "http:" && url.hostname === "127.0.0.1" &&
      !url.username && !url.password && url.pathname === "/page" &&
      sender.url === message.pageURL &&
      typeof message.case === "string" && message.case.length > 0 &&
      url.searchParams.get("case") === message.case &&
      typeof message.requestID === "string" && /^[a-f0-9-]{36}$/.test(message.requestID) &&
      Number.isInteger(sender.tab?.id) && sender.tab.id >= 0 &&
      sender.frameId === 0 && typeof message.expectedTitle === "string";
  } catch {
    return false;
  }
}

function validSender(message, sender) {
  return validPageSender(message, sender) &&
    Number.isInteger(sender.tab.windowId) && sender.tab.windowId >= 0;
}

function senderFailureDetail(message, sender) {
  let senderURL = null;
  try { senderURL = new URL(sender?.url); } catch { /* Invalid or absent URL. */ }
  const checks = {
    extensionID: sender?.id === chrome.runtime.id,
    loopbackPage: senderURL?.protocol === "http:" && senderURL.hostname === "127.0.0.1" &&
      !senderURL.username && !senderURL.password && senderURL.pathname === "/page",
    pageMatch: sender?.url === message.pageURL && senderURL?.searchParams.get("case") === message.case,
    requestID: typeof message.requestID === "string" && /^[a-f0-9-]{36}$/.test(message.requestID),
    tabID: Number.isInteger(sender?.tab?.id) && sender.tab.id >= 0,
    windowID: Number.isInteger(sender?.tab?.windowId) && sender.tab.windowId >= 0,
    frameID: sender?.frameId === 0,
    expectedTitle: typeof message.expectedTitle === "string"
  };
  const missing = Object.entries(checks).filter(([, passed]) => !passed).map(([name]) => name);
  return `Invalid sender metadata: ${missing.join(",") || "unclassified"}`;
}

function makeRun(names, deadlineMs, sendResponse, envelope) {
  const results = new Map();
  let finished = false;
  const timer = setTimeout(() => finish("Worker deadline exceeded"), deadlineMs);

  function record(name, passed, detail) {
    if (!finished) results.set(name, { name, passed: passed === true, detail });
  }
  function finish(missingDetail = "Required worker result missing") {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    sendResponse({
      ...envelope,
      extensionID: chrome.runtime.id,
      workerRunID,
      results: names.map((name) => results.get(name) ?? { name, passed: false, detail: missingDetail })
    });
  }
  async function test(name, operation) {
    if (finished) return { passed: false };
    try {
      const outcome = await operation();
      record(name, outcome.passed, outcome.detail);
      return outcome;
    } catch (error) {
      const outcome = { passed: false, detail: protocol.errorDetail(error) };
      record(name, false, outcome.detail);
      return outcome;
    }
  }
  return { record, finish, test, active: () => !finished };
}

async function runTests(message, sender, sendResponse) {
  const envelope = {
    kind: protocol.replyKind,
    case: message.case,
    requestID: message.requestID
  };
  const run = makeRun(protocol.workerResultNames, protocol.workerDeadlineMs, sendResponse, envelope);
  const pageSenderIsValid = validPageSender(message, sender);
  const senderIsValid = validSender(message, sender);
  run.record("runtime.sender", senderIsValid,
    senderIsValid ? "Loopback top-frame sender has tab and window IDs" : senderFailureDetail(message, sender));
  const sentinel = `${protocol.sentinel}:${workerRunID}:${message.requestID}`;
  const markerValue = `${workerRunID}:${message.requestID}`;

  async function storageTests() {
    const profileCase = message.case?.startsWith("chrome-profiles-");
    const workerCase = message.case === "chrome-workers-a" || message.case === "chrome-workers-b";
    const phase = workerCase ? (message.case.endsWith("-a") ? "initial" : "restore") :
      new URL(message.pageURL).searchParams.get("phase");
    const persistenceValue = workerCase ? "chrome-workers" : message.case;
    const persistenceKey = "orbit.engineGate.extensionPersistence";
    let initialStorageExpected = true;
    if (profileCase || workerCase) {
      try {
        const previous = await protocol.apiCall("storage.local.get", () => chrome.storage?.local, "get", [[protocol.storageKey, persistenceKey]]);
        initialStorageExpected = phase === "initial" ?
          previous?.[protocol.storageKey] === undefined && previous?.[persistenceKey] === undefined :
          phase === "restore" && previous?.[persistenceKey] === persistenceValue;
      } catch {
        initialStorageExpected = false;
      }
    }
    const setResult = await run.test("storage.local.set", async () => {
      const values = { [protocol.storageKey]: sentinel };
      if (profileCase || workerCase) values[persistenceKey] = persistenceValue;
      await protocol.apiCall("storage.local.set", () => chrome.storage?.local, "set", [values]);
      return { passed: true, detail: "Synthetic sentinel written without an API error" };
    });
    await run.test("storage.local.get", async () => {
      const value = await protocol.apiCall("storage.local.get", () => chrome.storage?.local, "get", [[protocol.storageKey, persistenceKey]]);
      const matches = setResult.passed === true && value?.[protocol.storageKey] === sentinel && initialStorageExpected &&
        (!(profileCase || workerCase) || value?.[persistenceKey] === persistenceValue);
      return { passed: matches, detail: matches ?
        (profileCase || workerCase ? `Synthetic extension storage matched ${phase} expectation and readback` :
          "Exact synthetic sentinel read back") :
        initialStorageExpected ? "Sentinel missing, mismatched, or write failed" :
          "Extension storage did not match this synthetic profile phase" };
    });
  }

  async function senderTest(name, operation, requireWindow = false) {
    return run.test(name, async () => {
      if (!pageSenderIsValid || (requireWindow && !senderIsValid)) {
        throw new Error(requireWindow ? "Valid sender window ID is required" :
          "Valid sender page, tab, and frame IDs are required");
      }
      return operation();
    });
  }

  async function networkTests() {
    await run.test("dnr.resetDynamicRules", async () => {
      await protocol.apiCall("declarativeNetRequest.updateDynamicRules", () => chrome.declarativeNetRequest, "updateDynamicRules", [{ removeRuleIds: [protocol.ruleID] }]);
      return { passed: true, detail: "Previous synthetic rule removed" };
    });
    const echo = await senderTest("runtime.contentRoundTrip", async () => {
      const reply = await protocol.apiCall("tabs.sendMessage", () => chrome.tabs, "sendMessage", [sender.tab.id, {
        kind: protocol.echoKind,
        case: message.case,
        requestID: message.requestID,
        workerRunID
      }, { frameId: sender.frameId }]);
      const matches = reply?.kind === protocol.echoReplyKind && reply.requestID === message.requestID &&
        reply.case === message.case && reply.workerRunID === workerRunID;
      return { passed: matches, detail: matches ? "Frame-specific content reply received" : "Content reply mismatched", value: reply };
    });
    const baseline = echo.value?.baseline;
    const baselinePassed = echo.passed === true && baseline?.outcome === "response" && baseline.status === 200 && baseline.exactURL === true;
    run.record("dnr.baselineFetch", baselinePassed, baselinePassed ? 200 : `Baseline failed: ${baseline?.outcome ?? "missing"}; status ${baseline?.status ?? "none"}`);

    await run.test("dnr.updateDynamicRules", async () => {
      if (!pageSenderIsValid) throw new Error("Valid loopback page sender is required for the dynamic rule");
      const origin = new URL(sender.url).origin;
      await protocol.apiCall("declarativeNetRequest.updateDynamicRules", () => chrome.declarativeNetRequest, "updateDynamicRules", [{
        removeRuleIds: [protocol.ruleID],
        addRules: [{
          id: protocol.ruleID,
          priority: 1,
          action: { type: "block" },
          condition: {
            urlFilter: `|${origin}/blocked`,
            requestDomains: ["127.0.0.1"],
            resourceTypes: ["xmlhttprequest"]
          }
        }]
      }]);
      return { passed: true, detail: "Synthetic block rule installed without an API error" };
    });
    await run.test("dnr.getDynamicRules", async () => {
      const rules = await protocol.apiCall("declarativeNetRequest.getDynamicRules", () => chrome.declarativeNetRequest, "getDynamicRules", []);
      const matchingRules = Array.isArray(rules) ? rules.filter((rule) => rule.id === protocol.ruleID) : [];
      const rule = matchingRules[0];
      const matches = pageSenderIsValid && matchingRules.length === 1 && rule.priority === 1 && rule.action?.type === "block" &&
        rule.condition?.urlFilter === `|${new URL(sender.url).origin}/blocked` &&
        rule.condition.regexFilter === undefined &&
        JSON.stringify(rule.condition.requestDomains) === '["127.0.0.1"]' &&
        JSON.stringify(rule.condition.resourceTypes) === '["xmlhttprequest"]';
      return { passed: matches, detail: matches ? "Exact rule 1001 read back" : "Dynamic rule missing or mismatched" };
    });
  }

  try {
    await Promise.all([
      storageTests(),
      senderTest("tabs.get", async () => {
        const tab = await protocol.apiCall("tabs.get", () => chrome.tabs, "get", [sender.tab.id]);
        const matches = senderIsValid && tab?.id === sender.tab.id && tab.windowId === sender.tab.windowId &&
          tab.url === message.pageURL && tab.title === message.expectedTitle;
        return { passed: matches, detail: matches ? "Sender tab, window, URL, and synthetic title match" :
          senderIsValid ? "Sender tab metadata mismatched" : "Sender window ID is unavailable" };
      }),
      senderTest("tabs.query", async () => {
        const tabs = await protocol.apiCall("tabs.query", () => chrome.tabs, "query", [{ windowId: sender.tab.windowId }]);
        const matches = Array.isArray(tabs) ? tabs.filter((tab) => tab.id === sender.tab.id && tab.windowId === sender.tab.windowId) : [];
        if (message.case.startsWith("chrome-native-")) {
          const secondCase = message.case.endsWith("-b");
          const peerURL = new URL(message.pageURL);
          peerURL.searchParams.set("case", message.case.slice(0, -2) + "-a");
          const peers = secondCase && Array.isArray(tabs) ? tabs.filter((tab) => tab.url === peerURL.href) : [];
          const own = matches[0];
          const peer = peers[0];
          envelope.tabContext = own ? {
            windowID: own.windowId, tabID: own.id, splitViewID: own.splitViewId ?? null,
            peerTabID: peer?.id ?? null, peerWindowID: peer?.windowId ?? null,
            peerSplitViewID: peer?.splitViewId ?? null, tabCount: tabs.length
          } : null;
          const wantsSplit = secondCase && message.case.startsWith("chrome-native-split-");
          const splitMatches = wantsSplit ? Number.isInteger(own?.splitViewId) && own.splitViewId >= 0 &&
            peer?.splitViewId === own.splitViewId : own?.splitViewId === -1 && (!secondCase || peer?.splitViewId === -1);
          const peerMatches = !secondCase || peers.length === 1 && peer.id !== own?.id &&
            peer.windowId === sender.tab.windowId && peer.title === message.expectedTitle;
          const passed = matches.length === 1 && tabs.length === (secondCase ? 2 : 1) && peerMatches && splitMatches;
          return { passed, detail: passed ? "Native window tab count, peer identity, and split membership match" :
            "Native window peer, tab count, or split membership mismatched" };
        }
        return { passed: matches.length === 1, detail: matches.length === 1 ? "Sender tab found in its own window" : "Sender tab absent or duplicated" };
      }, true),
      senderTest("scripting.executeScript", async () => {
        const injections = await protocol.apiCall("scripting.executeScript", () => chrome.scripting, "executeScript", [{
          target: { tabId: sender.tab.id, frameIds: [sender.frameId] },
          world: "ISOLATED",
          func: (attribute, value, expectedURL) => {
            if (location.href !== expectedURL || !document.documentElement) return false;
            document.documentElement.setAttribute(attribute, value);
            return document.documentElement.getAttribute(attribute) === value;
          },
          args: [protocol.markerAttribute, markerValue, message.pageURL]
        }]);
        const matches = Array.isArray(injections) && injections.length === 1 &&
          injections[0].frameId === sender.frameId && injections[0].result === true;
        return { passed: matches, detail: matches ? "Sender-frame injection returned the marker readback" : "Injection result missing or mismatched" };
      }),
      networkTests(),
      run.test("permissions.contains", async () => {
        const contains = await protocol.apiCall("permissions.contains", () => chrome.permissions, "contains", [{
          permissions: ["storage", "tabs", "scripting", "declarativeNetRequest"],
          origins: ["http://127.0.0.1/*"]
        }]);
        return { passed: contains === true, detail: contains === true ? "Declared permissions are granted" : "Declared permissions are not granted" };
      })
    ]);
    run.finish();
  } catch (error) {
    run.finish(`Worker execution failed: ${protocol.errorDetail(error)}`);
  }
}

async function cleanup(message, sender, sendResponse) {
  const run = makeRun(["dnr.cleanupDynamicRule"], protocol.cleanupDeadlineMs, sendResponse, {
    kind: protocol.cleanupReplyKind,
    case: message.case,
    requestID: message.requestID
  });
  await run.test("dnr.cleanupDynamicRule", async () => {
    if (!validPageSender(message, sender)) throw new Error("Valid loopback page sender is required for cleanup");
    await protocol.apiCall("declarativeNetRequest.updateDynamicRules", () => chrome.declarativeNetRequest, "updateDynamicRules", [{ removeRuleIds: [protocol.ruleID] }]);
    if (!run.active()) throw new Error("Cleanup deadline exceeded");
    const rules = await protocol.apiCall("declarativeNetRequest.getDynamicRules", () => chrome.declarativeNetRequest, "getDynamicRules", []);
    const removed = Array.isArray(rules) && rules.every((rule) => rule.id !== protocol.ruleID);
    return { passed: removed, detail: removed ? "Rule 1001 removed and absence read back" : "Rule 1001 remains or readback is invalid" };
  });
  run.finish();
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.kind === protocol.runKind) {
    void runTests(message, sender, sendResponse);
    return true;
  }
  if (message?.kind === protocol.cleanupKind) {
    void cleanup(message, sender, sendResponse);
    return true;
  }
  return false;
});
