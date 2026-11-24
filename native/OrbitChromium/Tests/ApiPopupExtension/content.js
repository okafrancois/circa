// An inline "Unlock" button next to the page's first input, as a password manager offers.
// A click asks the service worker to open the action popup; the outcome is published on the
// page's root element for the probe (the DOM is shared with the page).
const root = document.documentElement;
const input = document.querySelector('input');
if (input) {
  const button = document.createElement('button');
  button.id = 'api-popup-unlock';
  button.textContent = 'Unlock';
  button.style.cssText = 'position:fixed;left:40px;top:80px;width:120px;height:40px;font:16px system-ui';
  button.addEventListener('click', async (event) => {
    // Each request reports under its own number: replies may arrive out of order.
    const request = Number(root.dataset.apiPopupClicks || 0) + 1;
    root.dataset.apiPopupClicks = String(request);
    root.dataset['apiPopupTrusted' + request] = String(event.isTrusted);
    const reply = await chrome.runtime.sendMessage({type: 'open-popup'});
    root.dataset['apiPopupUrlVisible' + request] = String(reply.urlVisible);
    root.dataset['apiPopupResult' + request] = reply.result;
  });
  document.body.appendChild(button);
  root.dataset.apiPopupReady = 'true';
}
