# Orbit — working agreement for agents

Orbit is a native macOS browser: Swift/AppKit shell (`native/Sources/Orbit`) on a maintained CEF/Chromium 158 engine (`native/OrbitChromium`). Releases ship through GitHub with Sparkle automatic updates (`docs/release/pipeline.md`).

## Roles and definition of done
- The PM (Claude) splits work, writes briefs, decides and merges into `main`. Implementation agents work in their own worktree and branch; only the PM merges and pushes.
- Done means: the feature works in the real Chromium product (synthetic test bundle), compiled, with targeted tests passing and a capture or real run. A proof that nothing can go wrong is not a deliverable.
- No review chains, hash receipts or handoff documents. One lot note of at most 60 lines: what works, how to try it, limits. Lot notes are local lab material: write them to `/Users/bernyitoutou/Developer/artlab/lab/notes/<lot>.md` (outside Git), never under `docs/`.
- Code, comments, test descriptions, commit messages and docs are in English. User-facing strings go through `uiText` and stay localizable.

## Building and testing
- Targeted tests: `swift test --package-path native --scratch-path <path owned by your worktree> --filter <Suite>`. Always add `LocalizationTests` to the filter: it checks every new user-facing string and literal.
- Full suite: always behind the shared lock, `/usr/bin/lockf -k /tmp/orbit-native-full-suite.lock swift test --package-path native --scratch-path <path> --jobs 6`. A timeout in an unrelated test is rerun in isolation before blaming the lot.
- Product: `CMAKE_BUILD_PARALLEL_LEVEL=4 python3 scripts/orbit-chromium-app.py build`. The prebuilt engine lives in `.tools/chromium-fork/distrib/` (not in Git); do not rebuild it unless the brief says so.
- Synthetic bundle for GUI checks: `python3 scripts/orbit-app.py build --synthetic`. It must never start outside its synthetic data root.

## Disk hygiene
- Disk space is shared by many parallel agents. When your lot is committed, delete everything you built that is no longer needed: SwiftPM scratch paths, CMake/ninja build directories, packaged synthetic bundles, synthetic data roots, downloaded fixtures and temporary files.
- Keep only the deliverables the PM reviews (the lot note, comparison images and videos, a short log), at most a few hundred MB, under `/tmp/<lot>/`.
- The PM removes the whole worktree after merging; never leave large outputs there.

## GUI runs
- Take the GUI slot with `/usr/bin/lockf -k /tmp/orbit-gui-slot.lock`, at most 60 s per session. Every session that shows a window, captures the screen or measures paint holds it, probes included; results gathered without the lock are invalid.
- During test runs, before every synthetic click, drag or keystroke, verify the target window belongs to your own test bundle's PID.
- The owner's real browser runs during your tests. Never address a process by name (System Events, `tell application`, `pgrep -x`): the name resolves to the owner's copy. Drive the test bundle only through PID-scoped Accessibility or its own probes, and capture only your test window (`screencapture -l <window id>`), never the full screen.
- The keyboard layout is French (AZERTY): send shortcuts by character (`osascript … keystroke "a" using command down`), never as US physical keys.
- Never install anything in `/Applications` or `~/Applications`. After a GUI run, remove what the test bundle left: `lsregister -u`, `defaults delete <test id>`, `tccutil reset All <test id>`, test Keychain items.

## Privacy and safety
- No personal content, browsing data, secrets or credentials in Git, logs or messages. Tests use the mock keychain and synthetic data roots.
- Back up real user data before any write; restore must be simple.
- Signing: release builds use the Developer ID configured in `release/config.json`; test bundles use `scripts/local_signing.py`. Never change Keychain ACLs or delete Safe Storage keys to work around prompts.

## Motion and design
- No reference, no design. A visible surface or transition is built only from real evidence of the reference: a capture or recording of it, or values recovered from its binary or resources. When that evidence is missing, stop that part and ask the PM for the exact capture you need. Never ship a plausible-looking reconstruction and list it under limits.
- Animated surfaces must match the design reference in curve, duration, direction, sequencing and the elements that appear during the transition. A static capture does not validate a transition: compare frame by frame and deliver side-by-side videos against the real reference.
- Known data (cached favicons, titles, URLs) renders without flicker.

## Releases
- `scripts/release.py` builds, signs, notarizes, packages and publishes. `.github/workflows/release.yml` runs it on a GitHub-hosted macOS runner (`xcode-27`, fresh VM, ephemeral credentials from repository secrets) when a `vX.Y.Z` or `vX.Y.Z-nightly.N` tag is pushed. Never register a self-hosted runner for this public repository, and never trigger releases from pull requests or forks.
- Stable releases roll out through Sparkle in daily phases (seven groups, one day apart); nightlies and manual **Check for Updates…** are immediate. Mark a stable security hotfix with `update: critical` in its release note only when every user must install it at once (`docs/release/pipeline.md`).
- Release cadence: after merging one or more user-visible features or fixes, the PM pushes `main` and tags the next version (patch for fixes, minor for new features). Installed copies update through Sparkle.
- Every `vX.Y.Z` tag ships with `release/notes/<version>.md`, committed before tagging, in the structured format of `docs/release/notes-format.md` (title sentence, New / Faster / Fixed / Smaller / Known limits; Faster items carry measured before → after numbers; an `engine` line whenever the engine or a bundled component changes). Run `python3 scripts/changelog.py build` and commit the regenerated `web/` changelog with the note. Published release notes are the source for public announcements, so list every new feature there; say so explicitly when a release only has internal fixes.
- Nightly channel: merged lots go out first as `vX.Y.Z-nightly.N` with a short note in `release/notes/nightly/`; promote to stable once the nightly ran without regression. Hotfixes may go straight to stable; engine changes always go through a nightly first.
- Feature clips: every lot that adds a user-visible feature delivers, from its validation GUI session, a silent clip of the feature in `/tmp/<lot>/` (≤15 s, H.264 MP4 without audio, ≤1440 px wide, ≤3 MB, plus a JPEG poster), recorded on synthetic data in the lot's own test window only — never reference footage or personal content. The PM adds it to the release note's `media`.

## Public repository hygiene
- This repository is public. Tracked files (code, comments, tests, docs, commit messages) never name or describe the design reference product, its binary, symbols, addresses, assets or recordings. Write neutral facts instead: "0.12 s ease-out", not where the value came from.
- The only exception is the user-facing import feature for that browser's data and the code that implements it.
- The website may name that browser only in `web/copy/reference.json`, which holds the import copy and the trademark notice. Every other file under `web/` stays neutral.
- Reference evidence, comparisons and lot notes stay in `lab/` or `/tmp`.

## Local lab material
- Research notes and historical references are kept outside Git in the main checkout's ignored `lab/` folder. Read them only when a brief points to them; never copy them into tracked files.

## Monorepo
- Keep `native/`, `scripts/`, `release/`, `docs/` and `.github/` at the repository root.
- Website and mobile projects belong in `web/` and `mobile/`; use `web-vX.Y.Z` and `mobile-vX.Y.Z` tags, publish with `--latest=false`, filter workflows to their own folder, and never use the browser release workflow or its runner.
- The website is static (no build) and deploys on Vercel from the `web/` root directory; `web/vercel.json` skips deploys when `web/` is unchanged.
