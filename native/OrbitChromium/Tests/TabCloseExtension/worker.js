function openDashboard() {
  chrome.tabs.create({ url: chrome.runtime.getURL("dashboard.html") });
}
chrome.runtime.onInstalled.addListener(openDashboard);
chrome.runtime.onStartup.addListener(openDashboard);
