# Engine r17

Side API v17 adds three native engine operations: `freeze_tab`, `purge_memory`, and `preconnect`. The CEF patch is based on the r16 CEF/Orbit commit recorded in `source.json`; the existing Chromium popup cancellation patch remains applied and is rechecked by the builder.

The change is CEF-side only. The build uses the maintained Chromium 156 security source and dependency pins in `source.json`, then stages `orbit-engine-extensions-r17` beside the active distribution.

Build and package:

```sh
python3 scripts/cef-engine-r17-build.py --jobs 8 --logs /tmp/engine-r17/build --dry-run
python3 scripts/cef-engine-r17-build.py --jobs 8 --logs /tmp/engine-r17/build --run-build --expected-tasks <count>
python3.12 scripts/package_ci_engine.py .tools/chromium-fork/distrib/orbit-engine-extensions-r17 \
  --output /tmp/engine-r17/orbit-engine-extensions-r17.tar.gz
```
