document.documentElement.dataset.pageProbe = 'loaded';
window.early = getComputedStyle(document.documentElement).getPropertyValue('--boost').trim();
window.pageIsolation = typeof globalThis.boostSecret;
window.chromeBinding = document.documentElement.dataset.binding;
function reportChild() {
  parent.parent.postMessage({
    child: true,
    early: window.early,
    live: getComputedStyle(document.documentElement).getPropertyValue('--boost').trim(),
    isolation: window.pageIsolation,
    zap: getComputedStyle(document.querySelector('#zap')).display,
    extension: document.documentElement.dataset.extension
  }, '*');
}
if (location.pathname.endsWith('child')) {
  reportChild();
  addEventListener('message', event => { if (event.data === 'report') reportChild(); });
} else {
  addEventListener('message', event => { if (event.data.child) window.childResult = event.data; });
}
