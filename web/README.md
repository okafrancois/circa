# Website

## Scope
The Circa website lives here, beside the browser project. It is a static site: plain HTML, CSS and JavaScript, with no build step.

```
web/
  index.html            The landing page
  changelog.html        Public release history, also linked from the native update card
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
- No external resources: fonts are the system's, scripts and images are served from this folder. The pages only call the public GitHub API for published release metadata. Changelog notes are rendered as text, never injected HTML.
- Lines that name another browser stay in `copy/reference.json`. The page reads correctly without that file.
- The Download buttons point to `https://github.com/okafrancois/circa/releases/latest/download/Circa.dmg`, uploaded with every browser release.
- Use tags `web-vX.Y.Z` for website releases. Always create GitHub releases with `--latest=false`. Website workflows must use `paths:` filters limited to `web/**` and must never run on the self-hosted browser runner.

## Changelog

`/changelog` serves `changelog.html` through clean URLs. Version anchors use `#vX.Y.Z`.
Recent verified entries are in the static HTML, so the page remains useful without JavaScript or API access.
Newer published `vX.Y.Z` browser releases load from GitHub; drafts, prereleases and other tag families are ignored.
Release content is inserted with DOM text nodes. Older history remains available through the GitHub archive link.
After publishing a release, no website redeployment is needed for its new entry to appear.

The ignored-build check compares against the previous successful deployment, so a push containing several commits still deploys website changes. A missing or unavailable base starts a deployment.
