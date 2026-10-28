globalThis.runCloseFixture = async function (mode) {
  const target = chrome.runtime.getURL("target.html");
  if (mode === "tabs") {
    const tab = await chrome.tabs.create({ url: target, active: false });
    setTimeout(() => chrome.tabs.remove(tab.id), 3000);
  } else if (mode === "page") {
    window.open(target + "#close");
  } else if (mode === "windows") {
    const tab = await chrome.tabs.create({ url: target, active: false });
    setTimeout(() => chrome.windows.remove(tab.windowId), 3000);
  } else if (mode === "dashlane") {
    window.open("https://check.dashlane.com/");
  }
  document.querySelector("#result").textContent = "Started: " + mode;
};
for (const button of document.querySelectorAll("button")) {
  button.addEventListener("click", () => runCloseFixture(button.dataset.mode));
}
