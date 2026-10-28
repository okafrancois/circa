# OrbitChromium — Chromium engine adapter, laboratory and product build

`ChromiumEngine`, an adapter of the `BrowserEngine` contract on the stock (unpatched) CEF 156 SDK,
with Alloy-style browsers parented to shell-owned AppKit views. Laboratory only; not linked into
the SwiftPM package and not a preview build.

- `Bridge/` — C ABI 5 (`OrbitChromiumBridge.h`) over CEF; main thread only.
- `ChromiumEngine/` — Swift adapter (`ChromiumBrowserEngine`, `ChromiumSurface`, `ChromiumRuntime`).
- `Lab/` — hidden laboratory driver (synthetic loopback fixtures, never-ordered windows; `HiddenGuard` blocks on-screen ordering and activation and monitors continuously).
- `WindowWatch/` — `OrbitWindowWatch`, the runner's out-of-process CGWindowList witness.
- `App/` — composition root of the **product** build of Orbit on Chromium (CHROMIUM-APP): hosted
  D-chrome engine, `Orbit.app` with five `Orbit Helper` bundles (`OrbitChromiumApp`, `package_orbit_app`).
- `Smoke/` — hidden smoke driver of that composition, built only into `smoke/Orbit.app`
  (`OrbitChromiumAppSmoke`, with `Lab/HiddenGuard.swift`); run by `scripts/orbit-chromium-app.py`.
  See `docs/native-port/chromium-app-2026-10-25.md`.

Build and run with `scripts/orbit-chromium-lab.py` (see
`docs/native-port/eng-x1-stock-adapter-2026-10-25.md`). Outputs stay in the ignored `build/`.

The adapter's lifecycle regression can run without CEF, windows, network, or Keychain access:

```sh
cmake --build native/OrbitChromium/build/release --target ChromiumLifecycleTests --parallel 2
native/OrbitChromium/build/release/Tests/ChromiumLifecycleTests
```

This target compiles the adapter's actual Swift files against `Tests/LifecycleBridgeStub.c`,
which supplies only synthetic native events. It checks disposal during pending creation followed
by `CREATE_ABORTED` while the Swift surface remains retained through engine shutdown. It does
not run the real CEF bridge or establish Chromium engine conformance.

Quit Apple Event routing has a separate CEF-free AppKit regression:

```sh
python3 scripts/test_orbit_application_quit.py -v
```

It compiles the product lifecycle class, dispatches real core/quit events to an owned hidden
application's exact PID, and checks cancellation/retry, deferred replies, duplicates, menu
termination and URL/document-handler preservation. Its sender can address only its parent
running the same synthetic executable. No windows, activation, signing, browser, network,
Keychain implementation or personal session root are involved. The runtime drain is replaced
with a sink: a signed Chromium candidate must still verify actual save/restore and CEF teardown.
See `docs/native-port/quit-appleevent-r1-2026-10-25.md`.
