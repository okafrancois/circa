# Website

## Scope
The Circa website lives here, beside the browser project. It is a static site: plain HTML, CSS and JavaScript, with no build step.

```
web/
  index.html            The landing page
  assets/               Styles, script, icons
  copy/reference.json   Every line that names another browser, loaded by the page
  vendor/gsap-3.13.0/   GSAP, served locally (see THIRD_PARTY_NOTICES.md)
  vercel.json           Hosting settings
```

## Preview locally
```
python3 -m http.server 4400 --directory web
```
Then open http://localhost:4400. Opening `index.html` from disk works too, but the reference copy and the version number only load over HTTP.

## Hosting
Vercel serves this folder as is: set the project's Root Directory to `web`, framework preset "Other", no build command. `vercel.json` skips deployments when nothing under `web/` changed, and sets the cache and security headers.

## Rules
- No external resources: fonts are the system's, scripts and images are served from this folder. The page only calls the GitHub API to show the current version.
- Lines that name another browser stay in `copy/reference.json`. The page reads correctly without that file.
- The Download buttons point to `https://github.com/okafrancois/circa/releases/latest/download/Circa.dmg`, uploaded with every browser release.
- Use tags `web-vX.Y.Z` for website releases. Always create GitHub releases with `--latest=false`. Website workflows must use `paths:` filters limited to `web/**` and must never run on the self-hosted browser runner.
