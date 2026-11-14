# Orbit signed release pipeline

## Configuration and prerequisites
- `release/config.json` is the single release configuration; initial version is **0.1.0**, bundle ID `io.github.okatech.orbit`.
- The Chromium product uses the maintained CEF/Chromium 158 fork (8127 branch). The
  `cef_flavor` in `release/config.json` and the descriptor in `release/engine.json` are
  the source of truth for the shipped engine; each engine's sources and patch union are
  recorded under `native/OrbitChromium/cef-patches/engine-r*/`.
- Keep the engine distribution under the repository's `.tools/chromium-fork/distrib/`.
  Worktrees reuse the main checkout's distribution; the pipeline does not build CEF.
- Security updates on the maintained branch: `scripts/cef-engine-security-update.py`
  moves the shared sources to a newer `158.0.8127.x` tag while preserving the patch union,
  a versioned `scripts/cef-engine-r*-build.py` exports a new flavor, and
  `scripts/package_ci_engine.py` produces the archive and descriptor for `release/engine.json`.
- Install Xcode/CLT, Python 3, CMake, Ninja, and `gh`; authenticate `gh` for the public
  repository `okafrancois/circa`. Nothing is published without `--publish`.
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
  the workflow. Publishing creates a draft, uploads all assets (including `appcast.xml`), then explicitly marks the browser version latest. It then creates or updates the `update-feed` prerelease and uploads the same appcast with `--clobber`; that tag does not match the browser release workflow trigger. Website and mobile releases must always use `--latest=false`.
- The app checks at launch and hourly (including a persisted-interval override), downloads signed
  updates silently, and offers a sidebar restart card. Pending installers are revalidated against
  a fresh feed before the card, restart and normal quit; stale installers are cancelled through
  Sparkle and replaced. If freshness cannot be verified, installation waits for a later check.
  On normal quit, a stale or unverifiable installer is cancelled and a fresh check is required
  on the next launch, rather than delaying quit to download another archive.
  The automatic-install switch persists under Sparkle's `SUAutomaticallyUpdate` key; availability
  checks stay enabled under `SUEnableAutomaticChecks`. Manual checks use the application menu's "Check for Updates…" item.
- Feed: `https://github.com/<repository>/releases/download/update-feed/appcast.xml`.
  The feed is signed: builds set `SURequireSignedFeed`, `generate_appcast` embeds the EdDSA
  feed signature, `release.py` re-signs idempotently with `sign_update`, requires the trailer and
  verifies it against `public_ed_key` before publishing. Builds without the key still read the
  signed feed, so the first signed release is also the transition. Editing a published feed by
  hand invalidates it for every current build: regenerate or re-sign it instead.
  `scripts/test_update_ux.py` covers the transition, the next signed feed and tampered or
  unsigned feeds (`signed-*` cases).
  For an engine migration, also run `--cases engine-transition --previous-app <verified-previous-app>`
  with the new product as `--source-app`. This re-signs a temporary copy of the previous
  product as a confined mock fixture and checks installation, relaunch and session restoration
  across the engine change; it never launches the supplied production bundle directly.
- **Update preservation gate (mandatory, automatic).** `release.py` runs it before anything is
  signed, notarized or published, for every publishing run and every build that is not an
  isolated `--local-test-root` E2E. It downloads the latest release from the public feed,
  verifies the feed and archive EdDSA signatures, the Developer ID team and that its build is
  older than the candidate, then runs `scripts/test_update_ux.py --cases auth-transition` from
  that release to the candidate. In two synthetic profiles:
  - sign-ins: persistent, session and HttpOnly cookies set on a loopback fixture stay
    authenticated after a restart, the signed update, a new login, another restart and the next
    update, without crossing profiles;
  - installed extensions: the previous engine installs a signed CRX3 through its extension
    updater (loopback only); identity, version, enabled and disabled states, pinning, granted
    permissions, the extension's `chrome.storage` data and its background and content-script
    operation must survive the same sequence, as seen by the fixture server, the engine's
    inventory and the profile files;
  - the candidate keeps a private pre-update copy of these records (see below).
  The gate accepts only this run's complete result (a fixed list of required checks, a run
  nonce, digests of the exact previous and candidate bundles). A failure, missing evidence,
  mismatched input, unreachable feed or unavailable GUI session stops the release; there is no
  skip option. Evidence: `dist/release/preservation-<build>/` (synthetic data only).
  `hosted-build.yml` runs the same gate with `--qualify-only` (no credentials) on every main
  push and pull request. Locally: `python3 scripts/release.py --qualify-only --skip-build`
  (GUI runs take `/tmp/orbit-gui-slot.lock`, at most 55 s per stage).
  `--auth-expect lost --extensions-expect record` documents an engine that drops data.
- **Engine migration backup.** Before the first launch of a different build, and before the
  engine opens any profile, the app copies `Local State` and each profile's `Secure
  Preferences`, `Preferences` and cookie database to `<data root>/EngineMigrationBackups/`
  (0700/0600, last three build changes, at most 30 days). Copies are never logged, uploaded or
  restored automatically. Restoring is a deliberate action on a stopped browser
  (`BrowserEngineMigrationBackup.restore`), which first saves the current files. Data deleted
  before this feature shipped cannot be recovered by it.
  A rollback uses a newer build number; preserve user data and never downgrade the schema blindly.

## GitHub-hosted macOS runners

- `hosted-build.yml` compiles the product and smoke application on an Apple Silicon
  `xcode-27` runner (currently a GitHub public-preview image), using the current SDK while retaining the app's deployment target.
  It runs for relevant changes to `main`, pull requests, and manual dispatches.
  Its short-lived unsigned artifact is for compilation checks, not installation.
- `release/engine.json` pins a prebuilt engine release asset and the archive,
  framework and wrapper SHA-256 values. `scripts/ci_engine.py` verifies them and
  installs into the fresh checkout. Engine assets use `engine-*` prereleases with
  `--latest=false`; they never replace the latest browser release.
- Hosted signing uses five encrypted repository secrets:
  `CIRCA_SIGNING_CERTIFICATE` (base64 PKCS#12), `CIRCA_SIGNING_PASSWORD`,
  `CIRCA_PROVISIONING_PROFILE` (base64), `CIRCA_SPARKLE_PRIVATE_KEY` (exported key),
  and `CIRCA_NOTARY_CREDENTIALS` (JSON). The latter accepts `apple_id`, `password`
  (an Apple app-specific password), `team_id`; or `key_base64`, `key_id`, and
  optional `issuer` for an App Store Connect API key.
- `scripts/ci_signing.py` imports credentials into a new runner-only keychain,
  creates a private release configuration and deletes credentials in an always-run
  cleanup step. It refuses local or self-hosted execution. Private files and keys
  are never included in build artifacts or source control.
- Before switching releases, manually run `release.yml` with `hosted=true` and
  `publish=false` with an existing version tag. Verification builds the selected
  workflow ref and uses the tag only as version metadata, without publishing or
  changing the update feed. Publishing always checks out the version tag.
  Verify the resulting artifact.
- Set repository variable `CIRCA_HOSTED_RELEASES=true` only after this verification.
  Future owner-pushed version tags then use GitHub's macOS runners. Without this
  variable, releases retain the existing self-hosted path. Neither release path
  runs for pull requests or forks.

## Self-hosted fallback runner
- Run `scripts/setup-release-runner.sh` explicitly on this Mac as the repository owner.
  It downloads/checksums the official ARM64 runner, requests a short-lived registration token
  via `gh api` (kept out of argv/logs), assigns `orbit-release`, installs/starts its launchd service.
- Provision CEF, signing identity and the backed-up EdDSA key on that machine first.
  Preserve `.tools/` and `dist/release/` in the runner checkout. The script was **not executed**.
- `.github/workflows/release.yml` runs only owner-pushed `v*` tags or owner dispatches
  in the configured repository; numeric repository ID, owner, actor and strict `vX.Y.Z` tag guards reject other targets. No PR trigger.
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

## Private iCloud organization sync
- Production config uses `~/Library/OrbitRelease/Orbit_Developer_ID.provisionprofile`.
  Install that external profile on each release runner; keep it outside Git with mode `0600`.
  Relative paths resolve beside the configuration; `~` expands to the runner user's home.
  An explicitly configured missing, expired or mismatched profile aborts the release.
  A deliberately unconfigured (`null`) profile retains the non-cloud signing path.
  Test bundles never receive iCloud capabilities.
- The release decodes the profile with `security cms -D`, checks expiration, distribution type,
  team, exact application ID, CloudKit container and Production environment, then embeds it at
  `Contents/embedded.provisionprofile`. Production Push capability is included when authorized.
- Nested code is signed first. Only the host receives the profile-authorized cloud entitlements;
  the signed entitlements and signer certificate are checked against the embedded profile.
- macOS uses `com.apple.application-identifier` and `com.apple.developer.aps-environment`.
  Apple's `icloud-services` wildcard authorizes the narrow signed request `['CloudKit']`;
  app, team, container and Production environment still require explicit authorization.
- Before any archive is created, the pipeline executes the signed main binary directly with
  `--orbit-verify-icloud`. A killed process, timeout, failed entitlement admission or unexpected
  report aborts packaging. This path exits before AppKit, CEF, preferences, Keychain, session
  configuration or CloudKit construction; it neither contacts nor activates a running Orbit.
  Expected output: `{"icloudAvailable":true,"storageInitialized":false}`, exit 0.
  This checks execution admission on the runner; notarization and signature checks still apply.
- The Production schema has `OrbitOrganizationV1.payload` (Bytes). The app uses only the private
  database and its `OrbitOrganization` custom zone; sync remains opt-in in General Settings.

### Renewing or replacing the profile
1. Before the profile or its selected Developer ID certificate expires, generate a new **Developer
   ID** distribution profile for App ID `io.github.okatech.orbit`, team `5Y39TTNCM7`, with iCloud /
   CloudKit container `iCloud.io.github.okatech.orbit` and production Push enabled. Select the
   Developer ID Application certificate matching the runner's private signing identity.
2. Download it outside Git, decode with `security cms -D -i <profile>` and check the expiration,
   certificate, exact app/team/container and Production environment. Preserve the old external
   file as a private backup, then replace the configured file and set mode `0600` on each runner.
   Renew the signing certificate separately if needed; update `identity` only when its name changes.
3. Run `python3 scripts/test_release.py`, then a local release with a fresh `--output` directory
   and the intended `--tag vX.Y.Z`, **without `--publish`**. This command creates no Git tag.
   It must pass the signed launch gate, notarization and stapling before the PM publishes.
4. Extract the resulting ZIP outside Applications. Run `codesign --verify --deep --strict <app>`,
   `codesign -d --entitlements - <app>`, `security cms -D -i <app>/Contents/embedded.provisionprofile`,
   `spctl -a -vv <app>` and `<app>/Contents/MacOS/Orbit --orbit-verify-icloud` (exit 0).
   Never open the production-ID bundle normally alongside a personal Orbit for this check.
   Retain verification evidence, then remove the local artifacts. The PM tags and publishes.


## Public release notes

Write concise user-facing notes in `release/notes/X.Y.Z.md` before tagging a browser release.
The publisher uses this file for the GitHub release; older releases without a file keep generated notes.
The website at https://circabrowser.com/changelog includes recent static notes and loads newer published
browser releases from the public GitHub API. Drafts, prereleases and non-browser tags are excluded.
The app's update card links to the staged version's notes; the Release Notes command links to the running
version. Sparkle appcasts also expose the full changelog URL.

## Release download counts

GitHub records a `download_count` for each release asset. These counts include automatic updates,
repeat requests, CI and validation downloads; they do not measure unique installations or active users.

Run **Release download statistics** from the repository's Actions tab to see its report in the run summary:
https://github.com/okafrancois/circa/actions/workflows/download-stats.yml

Locally, with GitHub CLI authenticated:

```sh
python3 scripts/download-stats.py
python3 scripts/download-stats.py --json
```

The report separates DMG installers, full ZIP updates and delta updates; it excludes feed and engine assets.
Totals include every published stable browser release even when the table shows only recent versions.
