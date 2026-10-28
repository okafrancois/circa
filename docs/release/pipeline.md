# Orbit signed release pipeline

## Configuration and prerequisites
- `release/config.json` is the single release configuration; initial version is **0.1.0**, bundle ID `io.github.okatech.orbit`.
- The Chromium product uses CEF 156, flavor `orbit-engine-extensions-r3`.
- Keep the engine distribution under the repository's `.tools/chromium-fork/distrib/`.
  Worktrees reuse the main checkout's distribution; the pipeline does not build CEF.
- Install Xcode/CLT, Python 3, CMake, Ninja, and `gh`; authenticate `gh` for the public
  repository `okafrancois/orbit-browser`. Nothing is published without `--publish`.
- Sparkle **2.10.1** is downloaded from its official GitHub release and SHA-256 checked.
  Source: https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1

## Production EdDSA key (PM + user, not created by this implementation)
1. Run `python3 scripts/sparkle_setup.py` to fetch the pinned tools.
2. Run `.tools/sparkle-2.10.1/bin/generate_keys --account orbit-browser` once.
3. Back up securely with `.tools/sparkle-2.10.1/bin/generate_keys --account orbit-browser -x /secure/backup/orbit-ed-key`.
4. Put only the printed public key in `public_ed_key`. Keep the backup outside Git.
   The private key stays in the runner's Keychain. Alternatively use an external private file
   via `--ed-key-file /secure/orbit-ed-key` or `ORBIT_ED_KEY_FILE` (never its contents in argv).
- Missing public key disables the app updater and prevents creating a signed release feed.

## Signing and notarization
- Default: `Developer ID Application: Berny François Itoutou (5Y39TTNCM7)`, verified
  with `security find-identity -v -p codesigning`; hardened runtime and secure timestamp.
- `identity: "local"` remains available only for isolated test configurations.
- The expected `notarytool_profile` is `orbit-notary`; releases fail before compilation if
  it is missing. It is now provisioned on this Mac; new runners provision it with
  `xcrun notarytool store-credentials orbit-notary --apple-id <Apple-ID> --team-id 5Y39TTNCM7`.
- Configured notarization submits/staples the app before archiving, then the signed DMG.
  The local test app 0.0.2 was notarized and stapled successfully (Accepted).
- CEF and Sparkle nested code are signed inside out with hardened runtime. CEF hosts/helpers
  receive JIT/executable-memory/library-validation entitlements; Sparkle retains its own ones.

## Build and publish
- Local: `python3 scripts/release.py --tag v0.1.0`.
- Published versions use tags `vX.Y.Z`; the short version is `X.Y.Z`, build number defaults
  to the full-history Git commit count. Increment `--build-number` for rebuilt tags if needed;
  every distributed build number must strictly increase. Do not replace published versions.
- Outputs: `dist/release/archives/Orbit-X.Y.Z.zip`, `appcast.xml`, deltas, plus the install DMG.
  Preserve this directory between releases for delta generation and previous appcast URLs.
- After separately pushing the reviewed tag, run the same command with `--publish`, or use
  the workflow. Publishing creates a draft, uploads all assets, then makes it latest.
- The app checks at launch and hourly, downloads signed updates silently, and installs on quit.
  Manual checks use the application menu's "Check for Updates…" item.
- Feed: `https://github.com/okafrancois/orbit-browser/releases/latest/download/appcast.xml`.
  A rollback uses a newer build number; preserve user data and never downgrade the schema blindly.

## Self-hosted runner (not registered in this lot)
- Run `scripts/setup-release-runner.sh` explicitly on this Mac as the repository owner.
  It downloads/checksums the official ARM64 runner, requests a short-lived registration token
  via `gh api` (kept out of argv/logs), assigns `orbit-release`, installs/starts its launchd service.
- Provision CEF, signing identity and the backed-up EdDSA key on that machine first.
  Preserve `.tools/` and `dist/release/` in the runner checkout. The script was **not executed**.
- `.github/workflows/release.yml` runs only owner-pushed `v*` tags or owner dispatches
  in `okafrancois/orbit-browser`; job guards reject forks and other actors. No PR trigger.
- GitHub Settings → Actions → General: require approval for **all outside collaborators**
  on fork pull-request workflows; keep fork write-token/secret access disabled and the default
  workflow token read-only. This release job explicitly requests `contents: write`.
- Add a tag ruleset for `v*` restricting creation/update/deletion to the owner. Restrict the
  runner group to this repository, never authorize a PR workflow to use the release runner.

ORBIT-RENAME is merged: packaging uses the Orbit executable, icon and product identity.

## Local proof (2026-10-28)
- `/tmp/orbit-release-e2e/result.json`: notarized **0.0.1 → 0.0.2**, build **1 → 2**;
  **193 KiB delta** ready in **4.04 s**, installed in **4.73 s**, successful relaunch.
- `full-zip/result.json`: Developer ID full ZIP ready **5.98 s**, installed **6.53 s**.
- `requests.log`, `signatures.txt`, `installed-version.json`: loopback download and signed code.
- `stapler-installed.log` validates the installed ticket; `gatekeeper.log`: Notarized Developer ID accepted.
- `before.png` / `after.png`: Chromium product on synthetic data; no personal browser used.
- Test-only identity `io.github.okafrancois.orbit.updatetest`, baked mock Keychain and root;
  every other synthetic/test bundle disables Sparkle. Test keys exist only as files in `/tmp`.
- Checks: 1,951 Swift tests passed under the shared lock; 42 Python release/packaging tests.
- Notary submission: `3dd1ea57-62f7-4416-bef9-dc2ccd0c7b08` **Accepted**; one test app, no DMG submission.
- After proof: remove test bundles/data/key, dedicated preferences, LaunchServices and TCC
  registrations, and only caches whose embedded app has the exact dedicated test identity.
- No push, remote tag/release, GitHub secret or runner registration was performed.
