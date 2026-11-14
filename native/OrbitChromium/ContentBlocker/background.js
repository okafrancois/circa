// Built-in content blocking. The browser shell writes one profile's configuration as cookies of
// a reserved, never-resolved host; this worker applies it to declarativeNetRequest and writes an
// acknowledgement back. Rulesets are disabled in the manifest, so nothing is blocked until the
// shell has said so: a missing or partial configuration keeps the last applied state.
//
//   c       "<revision>.<enabled 0|1>.<chunk count>", written last
//   h<n>    allowed hosts, "|"-separated, n < chunk count
//   ack     "<revision>.<enabled 0|1>", written here after the rules are in place

const CONFIG_HOST = "content-blocking.circa.invalid";
const CONFIG_URL = `https://${CONFIG_HOST}/`;
const RULESETS = ["easylist", "easyprivacy"];
const RESERVED_RULE = 1;
const ALLOWED_SITES_RULE = 2;
const SITE_PRIORITY = 1000;
const ALL_TYPES = ["main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
  "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other"];
const HOST = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/;

async function readConfiguration() {
  const cookies = await chrome.cookies.getAll({ url: CONFIG_URL });
  const values = new Map(cookies.map((cookie) => [cookie.name, cookie.value]));
  const header = /^(\d{1,19})\.([01])\.(\d{1,3})$/.exec(values.get("c") ?? "");
  if (!header) return null;
  const hosts = [];
  for (let index = 0; index < Number(header[3]); index += 1) {
    const chunk = values.get(`h${index}`);
    if (chunk === undefined) return null;  // Still being written; the header change follows.
    for (const host of chunk.split("|")) {
      if (host && HOST.test(host)) hosts.push(host);
    }
  }
  return { revision: header[1], enabled: header[2] === "1", hosts };
}

async function apply() {
  const configuration = await readConfiguration();
  if (!configuration) return;
  const enabled = await chrome.declarativeNetRequest.getEnabledRulesets();
  if (configuration.enabled) {
    const missing = RULESETS.filter((id) => !enabled.includes(id));
    if (missing.length) await chrome.declarativeNetRequest.updateEnabledRulesets({ enableRulesetIds: missing });
  } else if (enabled.length) {
    await chrome.declarativeNetRequest.updateEnabledRulesets({ disableRulesetIds: enabled });
  }
  const rules = [];
  if (configuration.enabled) {
    // The configuration host never leaves the browser, even through a proxy.
    rules.push({ id: RESERVED_RULE, priority: SITE_PRIORITY, action: { type: "block" },
      condition: { requestDomains: [CONFIG_HOST], resourceTypes: ALL_TYPES } });
    if (configuration.hosts.length) {
      rules.push({ id: ALLOWED_SITES_RULE, priority: SITE_PRIORITY, action: { type: "allowAllRequests" },
        condition: { requestDomains: configuration.hosts, resourceTypes: ["main_frame"] } });
    }
  }
  const current = await chrome.declarativeNetRequest.getDynamicRules();
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds: current.map((rule) => rule.id), addRules: rules });
  await chrome.cookies.set({ url: CONFIG_URL, name: "ack", secure: true, sameSite: "strict",
    value: `${configuration.revision}.${configuration.enabled ? 1 : 0}` });
}

let pending = Promise.resolve();
function schedule() {
  pending = pending.then(apply).catch((error) => console.error("content blocking", error));
}

chrome.cookies.onChanged.addListener(({ cookie, removed }) => {
  if (!removed && cookie.domain === CONFIG_HOST && cookie.name === "c") schedule();
});
chrome.runtime.onStartup.addListener(schedule);
chrome.runtime.onInstalled.addListener(schedule);
schedule();
