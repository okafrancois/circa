// Circa landing. Motion is deliberately sparse: one intro, one living window, one reveal per section.
document.addEventListener('DOMContentLoaded', () => {
  const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const root = document.documentElement;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const gsap = window.gsap;
  const motion = !reduced && !!gsap;

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
      $$('[data-version]').forEach(el => { el.textContent = `Version ${version}`; el.hidden = false; });
    }).catch(() => {});

  // ---------- The window cycles through Spaces ----------
  const SPACES = [
    { k: 'work', n: 'Work', tint: '#FBDFD5', tabs: [['#C2410C', 'F', 'Notes on a slower web'], ['#5E6AD2', 'L', 'Roadmap — Linear'], ['#F24E1E', 'F', 'Landing v4 — Figma'], ['#635BFF', 'S', 'Stripe Docs']] },
    { k: 'home', n: 'Home', tint: '#DCE3FB', tabs: [['#C2410C', 'F', 'Notes on a slower web'], ['#E50914', 'N', 'Tonight'], ['#1DB954', 'S', 'Sunday playlist'], ['#0F9D74', 'M', 'Weekend in Lisbon']] },
    { k: 'read', n: 'Reading', tint: '#FAEBBB', tabs: [['#C2410C', 'F', 'Notes on a slower web'], ['#111111', 'A', 'The long now'], ['#7C3AED', 'P', 'Saved for later']] },
    { k: 'side', n: 'Side project', tint: '#FBDCE5', tabs: [['#C2410C', 'F', 'Notes on a slower web'], ['#1F2328', 'G', 'circa / pull requests'], ['#F5A623', 'N', 'Launch notes']] },
  ];
  const win = $('.win'), tabsEl = $('#tabs'), nameEl = $('#spn');
  let current = 0, timer = null, heroVisible = true;

  const tabHTML = s => s.tabs.map((t, i) =>
    `<div class="tab${i === 0 ? ' on' : ''}"><i class="fav" style="background:${t[0]}">${t[1]}</i><span>${t[2]}</span></div>`).join('');

  function setSpace(i) {
    current = i;
    const s = SPACES[i];
    $$('.hpw .pl').forEach(el => { el.style.opacity = el.classList.contains('hp-' + s.k) ? 1 : 0; });
    $$('.swi .sw').forEach(el => {
      const on = el.classList.contains('sw-' + s.k);
      if (motion) gsap.to(el, { width: on ? 21 : 15, height: on ? 21 : 15, opacity: on ? 1 : .5, duration: .35, ease: 'back.out(2.5)' });
      else Object.assign(el.style, { width: on ? '21px' : '15px', height: on ? '21px' : '15px', opacity: on ? 1 : .5 });
    });
    if (!motion) { win.style.background = s.tint; nameEl.textContent = s.n; tabsEl.innerHTML = tabHTML(s); return; }
    gsap.to(win, { backgroundColor: s.tint, duration: .6, ease: 'power2.out' });
    gsap.to([nameEl, tabsEl], {
      opacity: 0, y: -6, duration: .16, ease: 'power1.in', overwrite: true,
      onComplete() {
        nameEl.textContent = s.n; tabsEl.innerHTML = tabHTML(s);
        gsap.fromTo([nameEl, tabsEl], { opacity: 0, y: 8 }, { opacity: 1, y: 0, duration: .3, ease: 'power2.out' });
      },
    });
  }
  function schedule() {
    clearInterval(timer);
    if (!motion || !heroVisible) return;
    timer = setInterval(() => setSpace((current + 1) % SPACES.length), 4500);
  }
  $$('.swb').forEach(b => b.addEventListener('click', () => { setSpace(+b.dataset.space); schedule(); }));

  // ---------- Satellites on their orbits ----------
  function orbit(back, front, cx, cy, rx, ry, tilt, speed, start = 1.2) {
    const c = Math.cos(tilt * Math.PI / 180), s = Math.sin(tilt * Math.PI / 180);
    const place = a => {
      const x = rx * Math.cos(a), y = ry * Math.sin(a), isFront = Math.sin(a) > 0;
      gsap.set(isFront ? front : back, { x: cx + x * c - y * s, y: cy + x * s + y * c, opacity: 1 });
      gsap.set(isFront ? back : front, { opacity: 0 });
    };
    if (!motion) return place(start);
    let a = start;
    gsap.ticker.add((t, dt) => { a += dt / 1000 * speed; place(a); });
  }
  if (gsap) {
    orbit('#sputB', '#sputF', 270, 236, 236, 74, -18, .3);
    orbit('#wsB', '#wsF', 100, 100, 92, 24, -16, .6, 2.2);
  }

  // Without motion, everything stays in its final state.
  if (!motion) { root.classList.remove('pre'); return; }

  // ---------- Intro ----------
  const intro = gsap.timeline({ defaults: { ease: 'power3.out' }, onComplete: schedule });
  intro
    .from('.nav', { y: -16, opacity: 0, duration: .5 })
    .from('h1 .ln > span', { yPercent: 110, duration: .9, stagger: .12, ease: 'power4.out' }, '-=.2')
    .from('.eye', { opacity: 0, duration: .5 }, '<')
    .from('#moon', { scale: .55, opacity: 0, svgOrigin: '270 236', duration: 1.2, ease: 'back.out(1.2)' }, '<.1')
    .from('.sub, .hero .cta', { opacity: 0, y: 14, stagger: .08, duration: .6 }, '-=.8')
    .from('.winwrap', { y: 50, opacity: 0, duration: 1, ease: 'power3.out' }, '-=.5')
    .from('.stick', { scale: 0, rotation: -90, duration: .8, ease: 'back.out(1.8)' }, '-=.35');
  root.classList.remove('pre');

  gsap.to('#moon', { y: -6, duration: 4.5, repeat: -1, yoyo: true, ease: 'sine.inOut' });
  gsap.to('#stxt', { rotation: 360, svgOrigin: '60 60', duration: 30, repeat: -1, ease: 'none' });

  // ---------- One reveal per section ----------
  const reveals = [];
  function reveal(sel, build) {
    const el = $(sel); if (!el) return;
    const tl = gsap.timeline({ paused: true, defaults: { ease: 'power3.out' } });
    build(tl);
    reveals.push({ el, tl });
  }
  const heading = sel => tl => tl.from(`${sel} h2 .ln > span`, { yPercent: 110, duration: .8, ease: 'power4.out' });

  reveal('.band', tl => tl.fromTo('.patch', { scale: .4, opacity: 0 }, { scale: 1, opacity: 1, stagger: .08, duration: .6, ease: 'back.out(1.7)' }));
  reveal('.feat', tl => { heading('.feat')(tl); tl.fromTo('.fc', { y: 40, opacity: 0 }, { y: 0, opacity: 1, stagger: .07, duration: .7 }, '-=.4'); });
  reveal('.spaces', tl => {
    heading('.spaces')(tl);
    tl.fromTo('.pcard', { y: 40, opacity: 0 }, { y: 0, opacity: 1, stagger: .1, duration: .7 }, '-=.4');
  });
  reveal('.move', tl => {
    heading('.move')(tl);
    const path = $('#mvp'), len = path.getTotalLength(), o = { t: 0 }, t = $('#mvT');
    const put = () => {
      const a = path.getPointAtLength(o.t * len), b = path.getPointAtLength(Math.min(len, o.t * len + .5));
      const w = t.parentNode.clientWidth, h = t.parentNode.clientHeight;
      const ang = Math.atan2((b.y - a.y) * h, (b.x - a.x) * w) * 180 / Math.PI;
      gsap.set(t, { left: a.x + '%', top: a.y + '%', rotation: ang, opacity: o.t > .03 && o.t < .95 ? 1 : 0 });
    };
    tl.fromTo('.wp > *', { opacity: 0, y: 12 }, { opacity: 1, y: 0, stagger: .3, duration: .5 }, '-=.3')
      .to(o, { t: 1, duration: 2.4, ease: 'power1.inOut', onUpdate: put }, '<');
  });
  reveal('.fin', tl => { heading('.fin')(tl); tl.from('#hmoon', { y: 160, duration: 1.4, ease: 'power3.out' }, '<.1'); });

  // Plain geometry on scroll: a section plays once its top passes 85% of the viewport.
  // (More predictable than IntersectionObserver with fast or programmatic scrolling.)
  const hero = $('.hero');
  let queued = false;
  function check() {
    queued = false;
    const vh = innerHeight;
    for (let i = reveals.length - 1; i >= 0; i--) {
      const top = reveals[i].el.getBoundingClientRect().top;
      if (top < vh * .85) { reveals[i].tl.play(); reveals.splice(i, 1); }
    }
    // The window only cycles while the hero is on screen.
    const visible = hero.getBoundingClientRect().bottom > 0;
    if (visible !== heroVisible) { heroVisible = visible; if (intro.progress() === 1) schedule(); }
  }
  addEventListener('scroll', () => { if (!queued) { queued = true; requestAnimationFrame(check); } }, { passive: true });
  addEventListener('resize', check);
  check();
});
