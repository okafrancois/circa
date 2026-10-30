# Native security and page services

Chromium 156.0.8078.80 on the maintained 8078 branch. `source.json` pins the upstream
release; `cef.patch` is additive to the complete r12 CEF/Orbit patch union.
The Chromium and dependency changes come from the upstream release and its DEPS.

`scripts/cef-engine-security-update.py --version 156.0.8078.80 --logs <fresh-dir>`
preserves and reapplies the existing source changes under the shared source lock.
Stop on conflicts, inspect their scope, and refresh the affected engine hunks before
building. `scripts/cef-engine-r13-build.py` builds the composed source at nice 10,
Ninja at most eight jobs, and exports a separate distribution. Earlier exports remain intact.

Side API v14 adds native security snapshots/notifications, the security-display
formatter, the last committed URL, fullscreen origin notifications, indexed navigation
entries and navigation to an index. v15 adds native media metadata, artwork URLs,
playback/position, notifications and play/pause/seek/next/previous actions. Null observers
unregister; strings are borrowed only until the callback returns. All APIs run on UI.

The one-time permission operation matches the native browser/prompt IDs and uses
Chromium's AcceptThisTime path. Only Chromium-supported temporary permission kinds
are admitted; unsupported kinds fail closed. The public CEF API and its hash are unchanged.
Swift's `BrowserPermissionDecision.grantOnce` selects this path; persistent `.grant`
keeps its earlier behavior. The shell's permission policy is a separate consumer.

`BrowserEngineSurface.nativePageServices` supplies the Swift wrappers. No visible
controls or production polling are installed. Security display text is for presentation
only; consumers must use the committed URL accessor for navigation identity.

Qualification: `scripts/check_cef_security_api.py` checks the real v1-v15 ABI and
rejects v0/v16 without launching CEF; `scripts/orbit-engine-security-smoke.py` checks a
confined synthetic product against loopback fixtures under the shared GUI lock.
