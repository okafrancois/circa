# Popup lookup latency engine (r19)

This revision preserves the r18 security, popup cancellation and native-window
union. It adds `../extension-popup-latency/cef.patch` without changing the side
API (v18). Only unowned native extension popup frames receive the existing
excluded-frame response; normal and extension tabs retain browser registration.

Build in the locked, preserved incremental cache:

```sh
python3 scripts/cef-engine-r19-build.py --jobs 4
```

The builder checks the r18 source pins and both baseline patch fingerprints,
validates the incremental input/output bytes, and refuses to replace an existing
r19 distribution. r18 remains available. The exported manifest records the
incremental patch and output fingerprints in addition to the framework hash.
CEF's generated version retains its source lineage; the distribution flavor
identifies r19. `--dry-run` checks the composition and plans Ninja tasks without
compiling or exporting; it may apply the pinned source patches.

Validate an already patched checkout without modifying it:

```sh
python3 scripts/check_popup_latency_patch.py --cef-source /path/to/src/cef --applied
```

Synthetic validation uses the popup lifecycle smoke's four actions and the
performance probe's latency mode. `extension-controls/tab-registration` with a
fixture `extensionID` checks browser IDs, page commitment and renderer response
for a regular tab and a fixture extension page opened in a normal tab.
