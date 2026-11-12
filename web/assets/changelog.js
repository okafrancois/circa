document.addEventListener('DOMContentLoaded', () => {
  const releases = document.querySelector('#releases');
  const versions = document.querySelector('#versions');
  const search = document.querySelector('#release-search');
  const status = document.querySelector('#release-status');
  const repository = 'https://github.com/okafrancois/circa';
  const versionPattern = /^\d+\.\d+\.\d+$/;
  const requested = location.hash.replace(/^#v/, '');
  const initial = new Set([...releases.children].map(el => el.dataset.version));
  const compare = (a, b) => {
    const left = a.split('.').map(Number), right = b.split('.').map(Number);
    return left[0] - right[0] || left[1] - right[1] || left[2] - right[2];
  };
  const newestSeed = [...initial].sort(compare).at(-1);
  const element = (tag, text, className) => {
    const el = document.createElement(tag);
    if (text) el.textContent = text;
    if (className) el.className = className;
    return el;
  };
  // Lines that name another browser live in one file; the page reads well without it.
  fetch('copy/reference.json').then(r => r.ok ? r.json() : {}).then(copy => {
    document.querySelectorAll('[data-ref]').forEach(el => {
      const text = copy[el.dataset.ref];
      if (typeof text === 'string' && text) { el.textContent = text; el.hidden = false; }
    });
  }).catch(() => {});
  const filter = () => {
    const query = search.value.trim().toLowerCase();
    let count = 0;
    for (const article of releases.children) {
      article.hidden = !article.textContent.toLowerCase().includes(query);
      if (!article.hidden) count++;
    }
    document.querySelector('#no-releases').hidden = count !== 0;
  };
  search.hidden = false;
  search.addEventListener('input', filter);
  document.querySelector('#clear-search').addEventListener('click', () => {
    search.value = ''; filter(); search.focus();
  });
  let didJump = false;
  const jump = () => {
    const target = versionPattern.test(requested) && document.getElementById('v' + requested);
    if (target && !didJump) { target.scrollIntoView({ behavior: 'instant', block: 'start' }); didJump = true; }
  };
  jump();

  // GitHub is the release source; existing notes remain readable on rate limits or offline visits.
  // Render remote text with DOM textContent, never HTML from a release body.
  const render = release => {
    const version = release.tag_name.slice(1);
    const article = element('article', '', 'release');
    article.id = 'v' + version; article.dataset.version = version;
    const meta = element('div', '', 'release-meta');
    const heading = element('h2');
    const permalink = element('a', version);
    permalink.href = '#v' + version; permalink.setAttribute('aria-label', 'Link to version ' + version);
    heading.append(permalink);
    meta.append(heading);
    const date = new Date(release.published_at);
    if (Number.isFinite(date.getTime())) {
      const time = element('time', new Intl.DateTimeFormat('en', { dateStyle: 'long', timeZone: 'UTC' }).format(date));
      time.dateTime = date.toISOString().slice(0, 10); meta.append(time);
    }
    const copy = element('div', '', 'release-copy');
    // Keep the complete plain-text release notes, including stated limits. Links stay on GitHub.
    const body = typeof release.body === 'string' ? release.body.slice(0, 24000) : '';
    for (const block of body.split(/\n\s*\n/).filter(Boolean)) {
      const lines = block.split('\n').map(line => line.trim()).filter(Boolean);
      if (lines.every(line => /^[-*] /.test(line))) {
        const list = element('ul');
        for (const line of lines) list.append(element('li', line.replace(/^[-*] /, '')));
        copy.append(list);
      } else {
        copy.append(element('p', lines.join(' ').replace(/^#{1,6}\s*/, '')));
      }
    }
    if (!body.trim()) copy.append(element('p', 'Release details are available on GitHub.'));
    const source = element('a', 'Full release notes ↗', 'release-source');
    source.href = repository + '/releases/tag/v' + version; copy.append(source);
    article.append(meta, copy);
    return article;
  };
  const finish = () => {
    filter();
    if (versionPattern.test(requested)) {
      if (document.getElementById('v' + requested)) jump();
      else {
        status.replaceChildren(document.createTextNode('Looking for version ' + requested + '? '));
        const link = element('a', 'Read its release notes on GitHub.');
        link.href = repository + '/releases/tag/v' + requested;
        status.append(link); status.hidden = false;
      }
    }
  };
  fetch('https://api.github.com/repos/okafrancois/circa/releases?per_page=30', {
    headers: { Accept: 'application/vnd.github+json' }, credentials: 'omit', signal: AbortSignal.timeout(8000)
  }).then(response => {
    if (!response.ok) throw new Error('Unavailable');
    return response.json();
  }).then(data => {
    if (!Array.isArray(data)) throw new Error('Invalid releases');
    const updates = data.filter(release => release && !release.draft && !release.prerelease
      && typeof release.tag_name === 'string' && /^v\d+\.\d+\.\d+$/.test(release.tag_name)
      && !initial.has(release.tag_name.slice(1)) && compare(release.tag_name.slice(1), newestSeed) > 0)
      .sort((a, b) => compare(b.tag_name.slice(1), a.tag_name.slice(1)));
    for (const release of updates.reverse()) {
      const version = release.tag_name.slice(1);
      releases.prepend(render(release));
      const link = element('a', version); link.href = '#v' + version; versions.prepend(link);
    }
    finish();
  }).catch(() => {
    status.replaceChildren(document.createTextNode('Showing recent notes. '));
    const link = element('a', 'See all releases on GitHub.');
    link.href = repository + '/releases'; status.append(link); status.hidden = false;
    finish();
  });
});
