# Pending CEF essentials R2

Rebased privately on `lot/CEF-ESSENTIALS-R2`; original R1 was based on the draft from
`lot/CH-ESSENTIALS-MERGE@f8b3435`. Not applied to shared sources, compiled,
runtime validated, or admitted to `approved-builds.json`.

The outer patch applies with `git apply --index` to CEF
`0e3b767d39fa37f61101c2e31e945489789ed75d`. Its two nested Chromium patches
use **`git apply -p0`**, as CEF's patcher does, against the existing CEF-patched
Chromium `d0c02bfad08ec92a6ffcf989e53cd995e6381a4c` working files.
Exact input/output SHA-256 values are in
[`cef-essentials-r2-private.json`](../../../../docs/native-port/evidence/cef-essentials-r2-private.json).

R2 preserves API v3 logical Browser transfer holds and all existing nested patches.
The checker also requires exact reviewed working-file pins in
`cef-essentials-r2-base.json`; original R1 provenance remains historical.

Changes from the draft:

- Fix the missing comma between the existing `orbit_ext_window` and
  `orbit_native_side_panel` entries. Preserve all existing patch entries.
- Track Chrome's logical fullscreen separately from the AppKit shell's
  animated fullscreen style mask, including an already-fullscreen shell.
- Limit replacement of Chrome's folder confirmation to Orbit hosted tabs.
  Cancel a hosted directory request when the embedder declines handling it;
  never fall back to an unconfirmed native picker. The companion Orbit
  `OnFileDialog` handler must confirm before invoking its callback.
- Preserve the sad-tab null guard and the independent essentials-level export.

Reproduce private applicability checks (no compiler or browser execution):

```sh
python3 scripts/check_cef_essentials_patch.py \
  --chromium-source /path/to/chromium/src \
  --report /tmp/cef-essentials-r2-private.json
```

Do not use the original folder smoke as acceptance: it only proves that the
chooser was requested, then cancels it. An essentials level of 1 is an ABI gate,
not behavioral evidence. The companion Swift/bridge work is owned by
`lot/CH-INTEGRATION-essentials-dbg4`; it is intentionally not copied here.

See the [handoff and next-build protocol](../../../../docs/native-port/cef-essentials-r2-2026-10-25.md).
