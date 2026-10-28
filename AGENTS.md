# Orbit — working agreement for agents

Orbit is a native macOS browser: Swift/AppKit shell (`native/Sources/Orbit`) on a maintained CEF/Chromium 156 engine (`native/OrbitChromium`). Releases ship through GitHub with Sparkle automatic updates (`docs/release/pipeline.md`).

## Roles and definition of done
- The PM (Claude) splits work, writes briefs, decides and merges into `main`. Implementation agents work in their own worktree and branch; only the PM merges and pushes.
- Done means: the feature works in the real Chromium product (synthetic test bundle), compiled, with targeted tests passing and a capture or real run. A proof that nothing can go wrong is not a deliverable.
- No review chains, hash receipts or handoff documents. One lot note of at most 60 lines in `docs/`: what works, how to try it, limits.
- Code, comments, test descriptions, commit messages and docs are in English. User-facing strings go through `uiText` and stay localizable.

## Building and testing
- Targeted tests: `swift test --package-path native --scratch-path <path owned by your worktree> --filter <Suite>`.
- Full suite: always behind the shared lock, `/usr/bin/lockf -k /tmp/arcy-native-full-suite.lock swift test --package-path native --scratch-path <path> --jobs 6`. A timeout in an unrelated test is rerun in isolation before blaming the lot.
- Product: `CMAKE_BUILD_PARALLEL_LEVEL=4 python3 scripts/orbit-chromium-app.py build`. The prebuilt engine lives in `.tools/chromium-fork/distrib/` (not in Git); do not rebuild it unless the brief says so.
- Synthetic bundle for GUI checks: `python3 scripts/orbit-app.py build --synthetic`. It must never start outside its synthetic data root.

## GUI runs
- Take the GUI slot with `/usr/bin/lockf -k /tmp/arcy-gui-slot.lock`, at most 60 s per session.
- The keyboard layout is French (AZERTY): send shortcuts by character (`osascript … keystroke "a" using command down`), never as US physical keys.
- Never install anything in `/Applications` or `~/Applications`. After a GUI run, remove what the test bundle left: `lsregister -u`, `defaults delete <test id>`, `tccutil reset All <test id>`, test Keychain items.

## Privacy and safety
- No personal content, browsing data, secrets or credentials in Git, logs or messages. Tests use the mock keychain and synthetic data roots.
- Back up real user data before any write; restore must be simple.
- Signing: release builds use the Developer ID configured in `release/config.json`; test bundles use `scripts/local_signing.py`. Never change Keychain ACLs or delete Safe Storage keys to work around prompts.

## Motion and design
- Animated surfaces must match the design reference in curve, duration, direction and sequencing. A static capture does not validate a transition: compare frame by frame and deliver side-by-side videos.
- Known data (cached favicons, titles, URLs) renders without flicker.

## Releases
- `scripts/release.py` builds, signs, notarizes (`orbit-notary` profile), packages and publishes. It runs on the self-hosted runner when a `vX.Y.Z` tag is pushed. Never trigger releases from pull requests or forks.
- Release cadence: after merging one or more user-visible features or fixes, the PM pushes `main` and tags the next version (patch for fixes, minor for new features). Installed copies update through Sparkle.

## Local lab material
- Research notes and historical references are kept outside Git in the main checkout's ignored `lab/` folder. Read them only when a brief points to them; never copy them into tracked files.
