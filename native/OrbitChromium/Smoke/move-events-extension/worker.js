// CHROMIUM-APP-R2 hidden smoke: every tab move event, in order, reported to the loopback fixture
// that served the moved tab (POST /report, case "move-events"). Synthetic pages only.
const events = [];
let origin = null;

async function report() {
  if (!origin) return;
  try {
    await fetch(new URL("/report", origin), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ case: "move-events", events }),
    });
  } catch (error) {
    // The fixture may be gone at the end of a phase; the next event retries.
  }
}

async function record(kind, tabId, info) {
  try {
    const tab = await chrome.tabs.get(tabId);
    if (tab.url && tab.url.startsWith("http://127.0.0.1:")) origin = new URL(tab.url).origin;
  } catch (error) {}
  events.push({ kind, tabId, ...info, at: Date.now() });
  await chrome.storage.session.set({ events });
  await report();
}

chrome.tabs.onDetached.addListener((tabId, info) =>
  record("detached", tabId, { windowId: info.oldWindowId, index: info.oldPosition }));
chrome.tabs.onAttached.addListener((tabId, info) =>
  record("attached", tabId, { windowId: info.newWindowId, index: info.newPosition }));
chrome.tabs.onMoved.addListener((tabId, info) =>
  record("moved", tabId, { windowId: info.windowId, from: info.fromIndex, to: info.toIndex }));
