document.addEventListener('DOMContentLoaded', () => {
  // Optional import notice; release content is generated locally and needs no network.
  const prefix = document.querySelector('link[rel="stylesheet"]').getAttribute('href').replace(/assets\/.*$/, '');
  fetch(prefix + 'copy/reference.json').then(r => r.ok ? r.json() : {}).then(copy => {
    document.querySelectorAll('[data-ref]').forEach(el => {
      const text = copy[el.dataset.ref];
      if (typeof text === 'string' && text) { el.textContent = text; el.hidden = false; }
    });
  }).catch(() => {});
  const search = document.querySelector('#release-search');
  if (!search) return;
  const releases = [...document.querySelectorAll('#releases > .release')];
  const links = [...document.querySelectorAll('#versions > a')];
  const channels = [...document.querySelectorAll('input[name="channel"]')];
  const filter = () => {
    const query = search.value.trim().toLowerCase();
    const channel = channels.find(input => input.checked).value;
    let count = 0;
    for (const [index, article] of releases.entries()) {
      const visible = (channel === 'all' || channel === article.dataset.channel)
        && article.textContent.toLowerCase().includes(query);
      article.hidden = !visible;
      links[index].hidden = !visible;
      if (visible) count++;
    }
    document.querySelector('#no-releases').hidden = count !== 0;
  };
  const jump = () => {
    const target = releases.find(article => '#' + article.id === location.hash);
    if (!target) return;
    search.value = '';
    channels.find(input => input.value === target.dataset.channel).checked = true;
    filter();
    target.scrollIntoView({ block: 'start' });
  };
  search.hidden = false;
  document.querySelector('#search-label').hidden = false;
  search.addEventListener('input', filter);
  channels.forEach(input => input.addEventListener('change', filter));
  document.querySelector('#clear-search').addEventListener('click', () => {
    search.value = ''; channels[0].checked = true; filter(); search.focus();
  });
  window.addEventListener('hashchange', jump);
  filter();
  jump();
});
