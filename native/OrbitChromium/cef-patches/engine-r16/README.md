# Chromium 156.0.8078.88 security update

Weekly security update of the maintained 8078 branch from 156.0.8078.84 (r15) to
156.0.8078.88, the Extended Stable release of 2026-11-03. `source.json` pins the
release and the populated dependency checkouts. No new CEF/Orbit patch: the complete
r15 union (engine-r14 `cef.patch` on the CEF/Orbit branch plus
`popup-cancellation-r1/chromium.patch`) is reapplied unchanged. Side API stays v16.

Upstream DEPS changed only Git revisions (ANGLE, devtools-frontend, Skia, V8); no
CIPD, toolchain or hook input changed. CEF upstream on this branch only refreshed
patch offsets after the pinned CEF base, so the base is unchanged.

Procedure:

```sh
python3 scripts/cef-engine-security-update.py --version 156.0.8078.88 --logs /tmp/<fresh-logs>
python3 scripts/cef-engine-r16-build.py --jobs 8 --logs /tmp/<build-logs>
python3.12 scripts/package_ci_engine.py .tools/chromium-fork/distrib/orbit-engine-extensions-r16 \
  --output /tmp/<lot>/orbit-engine-extensions-r16.tar.gz
```

The packager prints the `release/engine.json` descriptor. Upload the archive to an
`engine-r16` prerelease (`--latest=false`) before pushing the descriptor; the hosted
build downloads it by URL and verifies every hash.
