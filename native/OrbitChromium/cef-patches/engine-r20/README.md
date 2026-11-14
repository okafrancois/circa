# Security roll engine (r20)

This revision moves the complete r19 union to the Chromium **156.0.8078.100**
security release without any other change: the r16 security and popup baseline,
v17 lifecycle, purge and preconnect APIs, v18 native developer-tools hosting and
source-window activation (`../engine-r18/{cef,chromium}.patch`), popup
cancellation (`../popup-cancellation-r1/chromium.patch`) and the r19 popup
lookup fix (`../extension-popup-latency/cef.patch`). The side API stays v18.

Between 156.0.8078.88 and .100 the roll changes 241 Chromium files and the v8,
skia, angle, dawn and icu revisions; DEPS has no CIPD, toolchain or hook change.
Four rolled files carry CEF patch changes (`DEPS`,
`manage_passwords_ui_controller.cc`, `navigation_request.{cc,h}`); they merge
without conflict. The angle, dawn and v8 overlays reapply on their new revisions.

Roll the shared source tree, then build in the preserved incremental cache:

```sh
python3 scripts/cef-engine-security-update.py --version 156.0.8078.100 --logs <fresh>
python3 scripts/cef-engine-r20-build.py --jobs 8
```

The update driver backs up every working diff before moving a repository and
reapplies it with a 3-way merge. The builder refuses any Chromium revision,
VERSION or dependency other than the pins in `source.json`, rejects conflict
markers in merged files, checks both baseline patch fingerprints and the popup
lookup bytes, and never replaces an existing r20 distribution. The exported
manifest records the Chromium tag and commit.

An incremental roll rebuilds the existing output in place, and the build loop
stops at 40 GiB free. `ORBIT_ENGINE_FREE_GIB_GUARD` may lower the 80 GiB start
guard for such a roll, never below 45 GiB.
