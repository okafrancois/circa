// Built-in content blocking. The browser shell writes one profile's configuration as cookies of
// a reserved, never-resolved host; this worker applies it to declarativeNetRequest and writes an
// acknowledgement back. Rulesets are disabled in the manifest, so nothing is blocked until the
// shell has said so: a missing or partial configuration keeps the last applied state.
//
//   c       "<revision>.<enabled 0|1>.<chunk count>[.s]", written last
//   h<n>    allowed hosts, "|"-separated, n < chunk count
//   ack     "<revision>.<enabled 0|1>", written here after the rules are in place
//
// ".s" marks a private context (an incognito split-mode instance reading its own off-the-record
// cookie store): its rules are session rules, which never reach disk and end with the extension's
// unload. Without it the rules are dynamic and survive a restart.

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
  const header = /^(\d{1,19})\.([01])\.(\d{1,3})(\.s)?$/.exec(values.get("c") ?? "");
  if (!header) return null;
  const hosts = [];
  for (let index = 0; index < Number(header[3]); index += 1) {
    const chunk = values.get(`h${index}`);
    if (chunk === undefined) return null;  // Still being written; the header change follows.
    for (const host of chunk.split("|")) {
      if (host && HOST.test(host)) hosts.push(host);
    }
  }
  return { revision: header[1], enabled: header[2] === "1", hosts, session: header[4] === ".s" };
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
  // The rules live in one store; the other one is emptied.
  const dynamic = await chrome.declarativeNetRequest.getDynamicRules();
  const session = await chrome.declarativeNetRequest.getSessionRules();
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds: dynamic.map((rule) => rule.id), addRules: configuration.session ? [] : rules });
  await chrome.declarativeNetRequest.updateSessionRules({
    removeRuleIds: session.map((rule) => rule.id), addRules: configuration.session ? rules : [] });
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

// A private context receives no cookie events (only the primary off-the-record store is
// observed), so its instance watches the header itself. The calls also keep it running for the
// context's lifetime.
if (chrome.extension?.inIncognitoContext) {
  let seen = null;
  setInterval(async () => {
    const header = await chrome.cookies.get({ url: CONFIG_URL, name: "c" });
    if (header && header.value !== seen) {
      seen = header.value;
      schedule();
    }
  }, 100);
}
chrome.runtime.onStartup.addListener(schedule);
chrome.runtime.onInstalled.addListener(schedule);
schedule();
