// chrome.action.openPopup() from a content-script message, then whether the call granted tab
// access: without the "tabs" permission a tab's URL is only visible under an activeTab grant,
// which the API path must not give.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type !== 'open-popup') return false;
  chrome.action.openPopup()
    .then(() => 'resolved', (error) => 'rejected: ' + error.message)
    .then(async (result) => {
      const [tab] = await chrome.tabs.query({active: true, lastFocusedWindow: true});
      sendResponse({result, urlVisible: Boolean(tab && tab.url)});
    });
  return true;
});
