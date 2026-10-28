// Synthetic loopback fixtures only. No extension API is emulated by the shell.
const defaults = Promise.all([
  chrome.action.setTitle({title: "Default action"}),
  chrome.action.setBadgeText({text: "D"}),
  chrome.action.setBadgeBackgroundColor({color: "#654321"}),
  chrome.action.enable()
]);
chrome.tabs.onUpdated.addListener(async (tabId, change, tab) => {
  if (!tab.url?.startsWith("http://127.0.0.1:")) return;
  const url = new URL(tab.url);
  if (url.searchParams.get("case") !== "engine-r4") return;
  await defaults;
  const badge = url.searchParams.get("badge") || "T1";
  await Promise.all([
    chrome.action.setTitle({tabId, title: "Tab " + badge}),
    chrome.action.setBadgeText({tabId, text: badge}),
    chrome.action.setBadgeBackgroundColor({tabId, color: "#123456"}),
    chrome.action.setIcon({tabId, path: "tab.png"}),
    badge === "T2" ? chrome.action.disable(tabId) : chrome.action.enable(tabId)
  ]);
});
