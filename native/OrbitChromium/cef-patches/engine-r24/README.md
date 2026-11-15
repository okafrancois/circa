# Side API v19 (r24)

r24 is the complete r23 composition (CEF 8127, Chromium **158.0.8127.37**, `engine-r21/cef.patch`,
`engine-r21/chromium.patch`, `engine-r22/os-crypt-owned-directory.patch` and
`engine-r23/system-passkeys.patch` unchanged) plus two deltas. No mojom, build file or public
CEF API change; the side API moves to v19 (additive, v18 is its prefix).

`chromium-delta.patch` (Chromium source tree):

1. **Embedder component extension.** `ComponentLoader::AddDefaultComponentExtensions` loads the
   unpacked directory named by `--orbit-component-extension` (set by the bridge only) as a
   component of every regular profile: hidden from the extensions page, not user-manageable,
   allowed in that profile's off-the-record contexts. The built-in blocker uses it.
2. **Per-group output volume.** `AudioOutputStreamBroker` hands each renderer a proxy of its audio
   service stream that multiplies the renderer's volume by its group's (one group per
   WebContents). `content::OrbitSetAudioGroupVolume(group, volume)` (any thread) sets it; tab
   capture follows the same level.
3. **Cookies events in every off-the-record context.** `CookiesEventRouter` opts into
   `ObservesEveryOffTheRecordContext()`; the lifetime tracker then reports every off-the-record
   profile to it (others still see the primary one only), and changes in each are dispatched to
   that context.

`cef-delta.patch` (CEF checkout, left uncommitted on the fork union):

4. **Side API v19.** `extension_action_detached` (popup in an engine-owned titled window: content
   size plus the native title bar, top-left 40 pt right and 10 pt below the source window's;
   follows content-size changes; closes on `window.close()`, Escape, its close button,
   `extension_cancel`, or when the source tab, window, extension or profile goes away),
   `tab_volume_set`/`tab_volume_get`, and `content_blocking_configure` (static rulesets on/off and
   the allowed-sites rule through `RulesMonitorService`: dynamic rules for a profile, session rules
   for its off-the-record contexts).
5. **Split-mode workers with their context.** `ChromeBrowserContext::ProfileCreated` creates the
   extension service worker task queue of each new off-the-record profile, which activates the
   split-mode extensions allowed there.

Rebuild on the r23 tree:

```sh
python3 scripts/cef-engine-r24-build.py --apply --jobs 8
```

The builder checks the r21 pins and unions, requires the r22 and r23 deltas, applies both r24
deltas under the shared source lock (the CEF delta may be the only uncommitted CEF change),
checks that the exported framework carries the v19 sources, and refuses to replace r24.
