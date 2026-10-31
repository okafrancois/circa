document.addEventListener('DOMContentLoaded', () => {
  const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const motion = !reduced && window.gsap && window.ScrollTrigger && window.CustomEase;
  const unhide = () => document.documentElement.classList.remove('pre');

  // Lines that name another browser live in one file; the page reads well without it.
  fetch('copy/reference.json').then(r => r.ok ? r.json() : {}).then(copy => {
    $$('[data-ref]').forEach(el => {
      const text = copy[el.dataset.ref];
      if (typeof text === 'string' && text) { el.textContent = text; el.hidden = false; }
    });
  }).catch(() => {});

  // Current version from the latest browser release; hidden when unavailable.
  fetch('https://api.github.com/repos/okafrancois/circa/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
    .then(r => r.ok ? r.json() : null)
    .then(release => {
      const version = release && typeof release.tag_name === 'string' ? release.tag_name.replace(/^v/, '') : '';
      if (!/^\d+(\.\d+)*$/.test(version)) return;
      $$('[data-version]').forEach(el => { el.textContent = `Version ${version} · `; el.hidden = false; });
    }).catch(() => {});

  // Theme toggle, remembered for next time.
  $('#themeToggle').addEventListener('click', () => {
    const next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem('circa-theme', next); } catch (e) {}
  });

  // Nav turns solid once the page scrolls.
  const nav = $('#nav');
  const onScroll = () => nav.classList.toggle('solid', scrollY > 20);
  addEventListener('scroll', onScroll, { passive: true }); onScroll();

  // ---------- The hero window: four Spaces, each with its gradient. Every site is fictional. ----------
  const SPACES = [
    { name: 'Work', grad: 'linear-gradient(170deg,#FF8A7A,#FF5A5F 45%,#7B4DFF)', accent: '#FF5A5F', glow: ['rgba(255,90,95,.42)', 'rgba(123,77,255,.26)'],
      url: 'docs.example/q4-roadmap', site: 'Docs', mark: '#FF5A5F', cat: 'Planning', title: 'Q4 roadmap', text: 'Three bets for the quarter, who owns them, and what we stop doing.', art: 'linear-gradient(150deg,#FFB4A6,#FF5A5F)',
      tabs: ['Q4 roadmap', 'Design review', 'Team calendar', 'Hiring pipeline'] },
    { name: 'Personal', grad: 'linear-gradient(170deg,#FFE27A,#FF9F45 50%,#FF5A5F)', accent: '#FF9F45', glow: ['rgba(255,159,69,.42)', 'rgba(255,90,95,.24)'],
      url: 'lisbon.guide/48-hours', site: 'Lisbon Guide', mark: '#FF9F45', cat: 'Travel', title: 'Forty-eight hours in Lisbon', text: 'Trams, tiles and the best custard tarts, walked in two days.', art: 'linear-gradient(150deg,#FFE27A,#FF9F45)',
      tabs: ['Forty-eight hours in Lisbon', 'Flights to Lisbon', 'Pastéis de nata', 'Weekend playlist'] },
    { name: 'Dev', grad: 'linear-gradient(170deg,#6E9BFF,#2D5BFF 45%,#1B2C8F)', accent: '#2D5BFF', glow: ['rgba(45,91,255,.42)', 'rgba(123,77,255,.24)'],
      url: 'lab.example/prototype-12', site: 'Lab', mark: '#2D5BFF', cat: 'Field notes', title: 'Prototype 12', text: 'What changed since the last build, and what still feels slow.', art: 'linear-gradient(150deg,#9FB8FF,#2D5BFF)',
      tabs: ['Prototype 12', 'Pull requests', 'Build logs', 'Staging'] },
    { name: 'Reading', grad: 'linear-gradient(170deg,#A7F3D6,#3DCCA0 50%,#2D5BFF)', accent: '#3DCCA0', glow: ['rgba(61,204,160,.36)', 'rgba(45,91,255,.24)'],
      url: 'longform.example/quiet-web', site: 'Longform', mark: '#3DCCA0', cat: 'Essay', title: 'The case for a quieter web', text: 'Fewer pop-ups, fewer tabs, more of the thing you came to read.', art: 'linear-gradient(150deg,#A7F3D6,#3DCCA0)',
      tabs: ['The case for a quieter web', 'On attention', 'A short history of tabs', 'Reading list'] }
  ];
  const win = $('#win'), hero = $('.hero');
  const dots = $('[data-dots]', win);
  dots.innerHTML = SPACES.map(s => `<button type="button" aria-label="${s.name}" aria-pressed="false"></button>`).join('');
  const siteHTML = s => `<div class="site"><header><i style="background:${s.mark}"></i>${s.site}<nav><span>Latest</span><span>Topics</span><span>About</span></nav></header>
    <div class="body"><div><div class="cat">${s.cat}</div><h3>${s.title}</h3><p>${s.text}</p><div class="lines"><i></i><i></i><i></i><i></i><i></i><i></i></div></div><div class="art" style="background:${s.art}"></div></div></div>`;
  let current = -1, timer = null;
  const show = i => {
    if (i === current) return;
    const dir = i > current ? 1 : -1; current = i;
    const s = SPACES[i];
    win.style.setProperty('--grad', s.grad); win.style.setProperty('--accent', s.accent);
    hero.style.setProperty('--glow-a', s.glow[0]); hero.style.setProperty('--glow-b', s.glow[1]);
    $('[data-url]', win).textContent = s.url; $('[data-space]', win).textContent = s.name;
    $('[data-tabs]', win).innerHTML = s.tabs.map((t, n) => `<li class="${n ? '' : 'on'}"><i></i>${t}</li>`).join('') + '<li class="fade"><i></i>Old search<small>11 h</small></li>';
    $$('button', dots).forEach((b, n) => b.setAttribute('aria-pressed', String(n === i)));
    const page = $('[data-page]', win), old = $('.site', page);
    page.insertAdjacentHTML('beforeend', siteHTML(s));
    const fresh = page.lastElementChild;
    if (old && motion) {
      gsap.to(old, { xPercent: -8 * dir, opacity: 0, duration: .4, ease: 'power2.in', onComplete: () => old.remove() });
      gsap.from(fresh, { xPercent: 8 * dir, opacity: 0, duration: .8, ease: 'circa', delay: .12 });
      gsap.from($$('[data-tabs] li', win), { x: -10, opacity: 0, duration: .6, ease: 'circa', stagger: .035 });
    } else if (old) old.remove();
  };
  const run = () => { clearInterval(timer); if (!reduced) timer = setInterval(() => show((current + 1) % SPACES.length), 3800); };
  $$('button', dots).forEach((b, n) => b.addEventListener('click', () => { show(n); run(); }));
  win.addEventListener('mouseenter', () => clearInterval(timer)); win.addEventListener('mouseleave', run);

  // Fixed-size window, scaled to its stage.
  const stage = $('#heroStage');
  const fit = () => stage.style.setProperty('--k', stage.clientWidth / 1100);
  new ResizeObserver(fit).observe(stage); fit();

  // ---------- Command Bar: a short demo until the visitor types. ----------
  const COLOURS = ['#FF5A5F', '#2D5BFF', '#3DCCA0', '#FF9F45'];
  const RESULTS = [
    ...SPACES.flatMap((s, si) => s.tabs.map((t, n) => ({ label: t, hint: s.name, colour: COLOURS[n % 4], space: si }))),
    ...SPACES.map((s, i) => ({ label: `Go to ${s.name}`, hint: 'Space', colour: s.accent, space: i })),
    { label: 'Open in Split View', hint: 'Action', colour: '#141317' },
    { label: 'Open in Little Circa', hint: 'Action', colour: '#7B4DFF' },
    { label: 'Boost this site', hint: 'Action', colour: '#FF5A5F' },
    { label: 'Import from Another Browser…', hint: 'Action', colour: '#FFD23F' }
  ];
  const input = $('#cmdInput'), list = $('#cmdList');
  const escape = q => q.replace(/[<&>"]/g, c => ({ '<': '&lt;', '&': '&amp;', '>': '&gt;', '"': '&quot;' })[c]);
  let matches = [];
  const render = raw => {
    const q = raw.trim().toLowerCase();
    const isQuestion = /\?$|^(how|what|why|when|where|which|who|can|should|is|are|does|do)\b/.test(q);
    if (isQuestion) {
      matches = [];
      list.innerHTML = `<li class="ask on"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3l1.8 4.6L18.5 9l-4.7 1.4L12 15l-1.8-4.6L5.5 9l4.7-1.4z"/><path d="M18.5 15l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8z" stroke="#FF5A5F"/></svg>Ask Claude Code<span class="soonx">Coming soon</span></li><li><i style="background:#141317"></i>Ask Codex<small>Coming soon</small></li><li class="empty">Search the web for “${escape(q)}”</li>`;
      return;
    }
    matches = q ? RESULTS.filter(r => r.label.toLowerCase().includes(q) || r.hint.toLowerCase().startsWith(q)).slice(0, 4)
                : ['Q4 roadmap', 'Go to Reading', 'Open in Split View', 'Import from Another Browser…'].map(l => RESULTS.find(r => r.label === l));
    list.innerHTML = matches.length ? matches.map((r, n) => `<li class="${n ? '' : 'on'}"><i style="background:${r.colour}"></i>${r.label}<small>${n ? '' : '↩ '}${r.hint}</small></li>`).join('')
      : `<li class="empty">Search the web for “${escape(q)}”</li>`;
  };
  const choose = r => { if (r && r.space !== undefined) { show(r.space); run(); } };
  render('');
  const DEMO = ['lisbon', 'road', 'what changed in swift 7?', 'split'];
  let demoOn = !reduced, demoTimer = null, demoStarted = false;
  const wait = ms => new Promise(r => demoTimer = setTimeout(r, ms));
  const typeDemo = async () => {
    for (let k = 0; demoOn; k = (k + 1) % DEMO.length) {
      for (let c = 1; c <= DEMO[k].length && demoOn; c++) { input.value = DEMO[k].slice(0, c); render(input.value); await wait(105); }
      if (!demoOn) break; await wait(1700); if (!demoOn) break;
      input.value = ''; render(''); await wait(800);
    }
  };
  const startDemo = () => { if (demoOn && !demoStarted) { demoStarted = true; typeDemo(); } };
  input.addEventListener('focus', () => { if (!demoOn) return; demoOn = false; clearTimeout(demoTimer); input.value = ''; render(''); });
  input.addEventListener('input', () => render(input.value));
  input.addEventListener('keydown', e => { if (e.key === 'Enter') choose(matches[0]); if (e.key === 'Escape') { input.value = ''; render(''); } });

  show(0); run();

  // ---------- Motion: one entrance, one reveal per section. ----------
  if (!motion) {
    unhide();
    if (!reduced) new IntersectionObserver((es, o) => es.forEach(e => { if (e.isIntersecting) { startDemo(); o.disconnect(); } }), { threshold: .4 }).observe($('.cmd'));
    return;
  }
  gsap.registerPlugin(ScrollTrigger, CustomEase);
  CustomEase.create('circa', 'M0,0 C0.19,1 0.22,1 1,1');
  CustomEase.create('stick', 'M0,0 C0.3,1.6 0.5,1 1,1');

  const split = el => {
    el.innerHTML = el.textContent.split(/\s+/).map(w => `<span class="w"><span class="wi">${w}</span></span>`).join(' ');
    return $$('.wi', el);
  };
  const heroWords = split($('#title'));

  const buildHero = () => {
    unhide();
    const tl = gsap.timeline({ defaults: { ease: 'circa' } });
    tl.from('.nav .wrap > *', { y: -12, opacity: 0, duration: 1, stagger: .08 }, 0)
      // The mark is slapped on like a sticker: outline first, then each band draws in.
      .from('#heroMark', { scale: .6, rotation: -14, opacity: 0, transformOrigin: '50% 70%', duration: .9, ease: 'stick' }, .1)
      .from('#heroMark .band', { strokeDasharray: '0 200', duration: .9, stagger: .12, ease: 'power3.out' }, .35)
      .from('.hero .eyebrow', { y: 12, opacity: 0, duration: 1 }, .45)
      .from(heroWords, { yPercent: 110, duration: 1.15, stagger: .07 }, .5)
      .from('.hero .lede, .hero .ctas, .hero .meta', { y: 18, opacity: 0, duration: 1.1, stagger: .08 }, .85)
      .from('#heroStage', { y: 130, opacity: 0, duration: 1.6 }, 1)
      .fromTo('.hero .sticker', { scale: 0, rotation: -20 }, { scale: 1, rotation: 8, duration: .7, ease: 'stick', clearProps: 'transform' }, 1.7);
    ScrollTrigger.refresh();
  };
  gsap.set('#heroMark .band', { strokeDasharray: '200 0' });
  Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 1200))]).then(buildHero);

  // Section reveals.
  $$('.sec, .close').forEach(sec => {
    const words = split($('[data-split]', sec));
    gsap.timeline({ scrollTrigger: { trigger: sec, start: 'top 72%' }, defaults: { ease: 'circa' } })
      .from(words, { yPercent: 110, duration: 1.1, stagger: .06 })
      .from($$('.sec-head p, .close p, .close .btn, .close .mark', sec), { y: 18, opacity: 0, duration: 1, stagger: .08 }, .25);
  });
  gsap.timeline({ scrollTrigger: { trigger: '.cmd-stage', start: 'top 75%' }, defaults: { ease: 'circa' }, onComplete: startDemo })
    .from('.cmd', { y: 50, opacity: 0, duration: 1.2 })
    .fromTo('.cmd-stage .sticker', { scale: 0, rotation: -30 }, { scale: 1, rotation: -7, duration: .7, ease: 'stick', clearProps: 'transform' }, .6);
  gsap.timeline({ scrollTrigger: { trigger: '#soon', start: 'top 80%' }, defaults: { ease: 'circa' } })
    .from('#soon', { y: 30, opacity: 0, duration: 1.1 })
    .fromTo('#soon .sticker', { scale: 0, rotation: -24 }, { scale: 1, rotation: 6, duration: .7, ease: 'stick', clearProps: 'transform' }, .5);
  gsap.from('.feat', { y: 22, opacity: 0, duration: 1, stagger: .05, ease: 'circa', scrollTrigger: { trigger: '.complete', start: 'top 82%' } });

  // The import card fills its bar and counts up once.
  const counts = $$('#importCard [data-count]');
  gsap.timeline({ scrollTrigger: { trigger: '#importCard', start: 'top 75%' }, defaults: { ease: 'circa' } })
    .from('.move .card', { y: 40, opacity: 0, duration: 1.2, stagger: .1 })
    .from('#importCard .bar i', { scaleX: 0, duration: 1.6, ease: 'power2.inOut' }, .4)
    .add(() => counts.forEach(el => { const n = +el.dataset.count, o = { v: 0 }; gsap.to(o, { v: n, duration: 1.4, ease: 'power2.out', onUpdate: () => el.textContent = Math.round(o.v) }); }), .4)
    .fromTo('#importCard .sticker', { scale: 0, rotation: -20 }, { scale: 1, rotation: 9, duration: .7, ease: 'stick', clearProps: 'transform' }, 1.9);
});
