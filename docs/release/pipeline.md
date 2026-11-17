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
   Local releases read the private key from the Keychain. Hosted releases receive the exported
   key as the `CIRCA_SPARKLE_PRIVATE_KEY` secret (see below). Alternatively use an external private
   file via `--ed-key-file /secure/orbit-ed-key` or `ORBIT_ED_KEY_FILE` (never its contents in argv).
- Missing public key disables the app updater and prevents creating a signed release feed.

## Signing and notarization
- Default: `Developer ID Application: Berny François Itoutou (5Y39TTNCM7)`, verified
  with `security find-identity -v -p codesigning`; hardened runtime and secure timestamp.
- `identity: "local"` remains available only for isolated test configurations.
- The expected `notarytool_profile` is `orbit-notary`; releases fail before compilation if
  it is missing. For a local release, provision it with
  `xcrun notarytool store-credentials orbit-notary --apple-id <Apple-ID> --team-id 5Y39TTNCM7`;
  hosted releases create it from `CIRCA_NOTARY_CREDENTIALS` in the ephemeral keychain.
- Configured notarization submits/staples the app before archiving, then the signed DMG.
  The local test app 0.0.2 was notarized and stapled successfully (Accepted).
- CEF and Sparkle nested code are signed inside out with hardened runtime; Sparkle retains its
  own entitlements. Developer ID builds scope code-signing exceptions per process:
  | Target | `com.apple.security.cs.*` |
  | --- | --- |
  | Host app | none (library validation stays on; device and iCloud/passkey capabilities only) |
  | Helper (Renderer); Helper (GPU), used only for the SwiftShader fallback | `allow-jit` |
  | Helper (GPU process and utility services, including the Widevine CDM signed by its vendor) | `disable-library-validation` |
  | Helper (Plugin), unused by this engine | `allow-unsigned-executable-memory`, `disable-library-validation` |
  | Helper (Alerts) | none |
  | Dock tile plug-in (`Contents/PlugIns/OrbitDockTile.docktileplugin`) | none, no entitlement at all |
  `release.py` fails after signing if the host carries any `cs.*` entitlement, a helper
  carries more than its set, or a plug-in carries any entitlement or is not the Dock tile plug-in.
  The `local` identity has no Team ID, so library validation cannot pass between its binaries:
  local test bundles keep all three exceptions on every helper and the host; the Dock tile
  plug-in never has any (the Dock's plug-in host loads it, not the app).

## Build and publish
- Local: `python3 scripts/release.py --tag v0.1.0`.
- Stable versions use tags `vX.Y.Z`; nightly versions use `vX.Y.Z-nightly.N` (N ≥ 1).
  The short version matches the tag without `v`; the build number defaults
  to the full-history Git commit count. Increment `--build-number` for rebuilt tags if needed;
  every distributed build number must strictly increase. Do not replace published versions.
- Outputs: `dist/release/archives/Orbit-X.Y.Z.zip`, `appcast.xml`, deltas, plus the install DMG.
  Preserve this directory between releases for delta generation and previous appcast URLs.
- After separately pushing the reviewed tag, run the same command with `--publish`, or use
  the workflow. Publishing creates a draft, uploads all assets (including `appcast.xml`), then marks stable browser versions latest; nightlies are prereleases with `--latest=false`. It then creates or updates the `update-feed` prerelease and uploads the same appcast with `--clobber`; that tag does not match the browser release workflow trigger. Website and mobile releases must always use `--latest=false`.
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
  isolated `--local-test-root` E2E. It downloads the required predecessors from the public feed (latest of any channel for a nightly;
  latest stable and latest nightly for a stable candidate),
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
  The same qualification also runs `--cases bundle-seal`: after signing a disposable
  predecessor, it adds the two generated blocker indexes inside its resources and requires
  its seal to fail verification. Sparkle must still install and relaunch the candidate.
  The candidate loads loopback ad/tracker fixtures in normal and private windows with
  blocking enabled, quits, and must pass `codesign --verify --deep --strict`. Generated
  indexes must exist only in the data root. Any missing check stops the release.
  `--cases bundle-seal bundle-seal-delta` additionally offers a signed delta and records
  delta/full archive requests. A damaged predecessor can require a full-download fallback;
  both cases must finish with a valid replacement seal.
  The gate accepts only this run's complete result (a fixed list of required checks, a run
  nonce, digests of the exact previous and candidate bundles). A failure, missing evidence,
  mismatched input, unreachable feed or unavailable GUI session stops the release; there is no
  skip option. Evidence: `dist/release/preservation-<build>-from-<previous>/` (synthetic data only).
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
  before this feature shipped cannot be recovered by it. A failed snapshot refuses startup before
  the engine can change profile files; the next launch retries.
  A rollback uses a newer build number; preserve user data and never downgrade the schema blindly.

## Nightly channel and promotion

- **Opt in:** Settings → Advanced → Receive nightly builds. The preference persists through
  updates. Nightlies offer new features first and may be less stable. Turning the switch off
  cancels a staged update and silently checks stable again; an installed nightly stays installed
  until a stable build has a greater build number. Sparkle never downgrades.
- One signed `update-feed/appcast.xml` serves everyone. Stable items have no channel; nightly
  items have `<sparkle:channel>nightly</sparkle:channel>`. Sparkle's delegate and the app's
  signed-feed freshness check both admit nightly only for opted-in users. Stable is always
  admitted. Sparkle 2.10.1 supports this directly (`allowedChannels`, `generate_appcast --channel`).
- **Cut a nightly (PM only):** choose the upcoming stable X.Y.Z and next N; commit 1–3 lines
  of user-facing notes to `release/notes/nightly/X.Y.Z-nightly.N.md`, then create and push
  `vX.Y.Z-nightly.N` through the normal release workflow. Locally, prepare with
  `python3 scripts/release.py --tag vX.Y.Z-nightly.N`; remote mutation still requires `--publish`.
  The current hook, `release_notes_path`, requires nonempty nightly notes before compilation;
  the shared notes validator can extend that hook without changing this directory contract.
- Nightly version releases are prereleases, always `--latest=false`. The fixed `nightly`
  prerelease holds a clobbered `Circa-Nightly.dmg`; https://circabrowser.com/nightly redirects
  there. The stable `releases/latest/download/Circa.dmg` and GitHub latest remain stable.
  Installing the nightly DMG does not opt the user into future nightlies; use the toggle.
- **Promote:** after nightly qualification, commit stable notes to `release/notes/X.Y.Z.md`
  and tag `vX.Y.Z` on a newer commit. Build numbers use full-history commit counts and must
  exceed every published channel, even when an explicit build number is supplied. A tag on
  the same nightly commit fails this requirement. Promotion builds a new stable artifact;
  it never changes a published nightly item or reuses its build number.
- **Hotfix:** a reviewed fix may go straight to a stable patch tag with stable notes. Its
  commit count must still exceed the newest nightly; bring the fix onto current history rather
  than publishing an older-count branch. Engine changes must go through nightly first.
- The mandatory preservation gate has no skip switch: nightly candidates qualify from the
  newest published build; stable candidates qualify separately from the latest stable and
  latest nightly (when present). Each predecessor retains signature, identity, monotonicity,
  authentication and extension checks. A failed predecessor blocks the release.
- The verified published feed seeds generation even on fresh runners. Existing entries and
  their archive/delta URLs are retained, then the combined feed is signed and verified again.
  Preserve local archives for new delta generation; a fresh runner still offers full archives
  and retains previously published deltas. Both channels remain in the single signed feed.
- Local channel qualification:
  `python3 scripts/test_update_ux.py --source-app <compiled-product> --cases channel-stable channel-opt-in channel-opt-out channel-tampered channel-staged-opt-out`.
  It uses only signed loopback feeds, temporary keys, mock Keychain and confined synthetic
  bundles, with the GUI slot held for each ≤55 s case. No production feed is modified.

## Content blocking rulesets
- The bundled extension is a read-only source. Before CEF starts, the bridge stages its
  four payload/license files under `<engine root>/ContentBlocking/v1-<SHA256>/`, publishing
  the complete directory by atomic rename. Chromium generates and validates its indexes
  there. Existing versions preserve their indexes; a change to any shipped byte selects a
  new version. The manifest key, extension ID and per-profile/private settings stay unchanged.
  Staging failure stops startup rather than loading from the signed bundle.
- From r24 (side API v19) the engine loads the staged copy as a component extension of every
  regular profile (`--orbit-component-extension`, set by the bridge only): it is absent from the
  extensions page and user management, and allowed in that profile's private contexts. The shell
  configures it in the browser process (`content_blocking_configure`): rulesets on or off and the
  excepted sites, persistent per profile and memory-only for private windows. The extension has
  no worker and no cookie channel. Engines before r24 leave the blocker unavailable.
- The built-in blocker ships declarativeNetRequest rulesets generated from EasyList and
  EasyPrivacy at the commit pinned in `release/content-blocking.json`. The data lives in
  `native/ThirdParty/easylist/` under its own license; the list texts are never committed.
- Refresh before tagging a release: `python3 -I scripts/content-blocking-rules.py update`
  pins the latest `gh-pages` commit, regenerates and keeps the previous pin. Review the diff
  and commit it with the release.
- Roll back: `python3 -I scripts/content-blocking-rules.py rollback` restores the previous pin and
  its rulesets (or revert the refresh commit).
- `release.py` runs `content-blocking-rules.py check`: the committed rulesets must match the
  pin's hashes and stay within the 30,000 guaranteed static rules.

## Stable phased rollout and critical updates

- Every stable candidate is generated with `generate_appcast --phased-rollout-interval 86400`:
  its item carries `<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>` and
  a `pubDate`. Sparkle 2.10.1 splits installations into seven random, persistent groups
  (`SUUpdateGroupIdentifier` % 7); group N sees the update N days after `pubDate` on scheduled
  background checks, so everyone has it after six days. Nightly items and isolated
  `--local-test-root` updater feeds are never phased.
- Sparkle ignores phasing for user-initiated checks: **Check for Updates…** always finds the
  newest build. The app's own feed freshness check applies the same group rule, so a staged
  older update is not replaced early by a build that the installation's group cannot see yet.
- To halt a bad stable release during its rollout, publish a fixed patch release (a newer build);
  remaining groups then receive the fix instead. Published items are never edited.
- **Critical updates** skip phasing and Sparkle shows them as critical (no skip button). Use one
  only for a stable security hotfix that every user must install now (an exploited or remotely
  reachable vulnerability, or broken update delivery). Declare it in the stable release note
  front matter with `update: critical`; `release.py` then passes `--critical-update-version ''`
  (critical for every installed version) instead of the phased interval. Nightly notes reject it.
- `release.py` checks the generated candidate before publishing: phased interval for stable,
  `<sparkle:criticalUpdate/>` only when the note declares it, neither for nightly.
- After a stable release, check the published `update-feed/appcast.xml`: the new stable item
  has the expected `pubDate`, `phasedRolloutInterval` 86400 and no channel; older items and
  nightly items are unchanged.

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
- `release.yml` runs only on the hosted `xcode-27` runner; its first step fails on any other
  runner. There is no self-hosted release runner and none may be registered for this public
  repository. Every run starts from a fresh VM: the engine comes from `release/engine.json`,
  credentials from the secrets above, and the previous feed from the published `update-feed`.
- To verify a release without publishing, manually run `release.yml` with `publish=false` and
  an existing version tag. Verification builds the selected workflow ref and uses the tag only
  as version metadata, without publishing or changing the update feed. Publishing always checks
  out the version tag. The signed artifacts are retained for three days.

## Release workflow guards
- `.github/workflows/release.yml` runs only owner-pushed `v*` tags or owner dispatches
  in the configured repository; numeric repository ID, owner, actor and strict `vX.Y.Z` / `vX.Y.Z-nightly.N` tag guards reject other targets. No PR trigger.
- GitHub Settings → Actions → General: require approval for **all outside collaborators**
  on fork pull-request workflows; keep fork write-token/secret access disabled and the default
  workflow token read-only. This release job explicitly requests `contents: write`.
- Add a tag ruleset for `v*` restricting creation/update/deletion to the owner.

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
  For a local release, install that external profile outside Git with mode `0600`; hosted
  releases decode `CIRCA_PROVISIONING_PROFILE` into the ephemeral signing directory.
  Relative paths resolve beside the configuration; `~` expands to the user's home.
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

## System passkeys
- The engine uses the macOS passkey provider (iCloud Keychain, the Passwords app and Touch ID)
  only when the host is signed with Apple's managed browser entitlement
  `com.apple.developer.web-browser.public-key-credential`. Apple grants it on request; it then
  appears in the regenerated Developer ID profile above.
- The release requests that entitlement for the host only when the embedded profile grants it
  (`true`). With the current profile nothing changes. When it is signed in, the pipeline also
  executes `<app>/Contents/MacOS/Orbit --orbit-verify-passkeys` before archiving and requires
  `{"browserPasskeys":true,"authorization":"…"}` (exit 0). That path reads the provider's
  authorization state without requesting it, so it never shows a prompt. The engine asks the
  user for authorization during the first ceremony.
- `webauthn_keychain_access_group` (optional) adds one `keychain-access-groups` value for the
  engine's own Touch ID authenticator. It must start with the team ID, be admitted by the
  profile, and appear verbatim in the engine binary; otherwise the release aborts. Engines from
  r23 compile in `5Y39TTNCM7.io.github.okatech.orbit.webauthn`, which the current profile admits
  (`5Y39TTNCM7.*`); earlier engines compile in a group without the team prefix, so the key must
  stay unset with them. The Touch ID check runs in the browser (host) process, so the group is
  signed on the host only. macOS refuses to launch a host that claims the group without a
  profile that admits it, so only the Developer ID release can carry it; test bundles never do.
- From r23, a page hosted directly in the browser's AppKit views (no Views widget) gives the
  system passkey provider the window that contains it. It only takes effect once the browser
  entitlement above is granted.
- After Apple approves the request: enable the capability on the App ID, regenerate the Developer
  ID profile with every existing capability, back up the old file, then replace it as described in
  *Renewing or replacing the profile*. Update the `CIRCA_PROVISIONING_PROFILE` secret as well
  if hosted releases are enabled. Check `security cms -D -i <profile>` shows the entitlement, then
  run the local release without `--publish`.
- Security keys and phones (hybrid) need no entitlement. Bluetooth access uses the existing
  `NSBluetoothAlwaysUsageDescription`.
- `scripts/orbit-passkeys-smoke.py` qualifies ceremonies in a synthetic bundle
  (`lab.orbit.orbit.passkeys-system`) with the engine's DevTools virtual authenticator, and
  captures and cancels the engine's authenticator dialog.


## Public release notes

Write structured user-facing notes in `release/notes/X.Y.Z.md` before tagging a browser release,
following [the release note format](notes-format.md). The publisher validates them before building
and renders the GitHub body without front matter. Run `python3 scripts/changelog.py build` and commit
the generated complete website history, per-version pages and Atom feed with each note change.
Optional nightly notes live in `release/notes/nightly/` and appear in their own filterable channel.
`python3 scripts/changelog.py check` verifies freshness offline; the website needs no GitHub API.
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
