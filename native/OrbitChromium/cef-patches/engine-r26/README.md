# UserScriptListener shutdown cleanup (r26)

r26 is the complete r25 composition (the r21 unions and the r22, r23 and r24 deltas on
Chromium **158.0.8127.65**, CEF 8127, side API v19) plus one Chromium delta,
`user-script-listener-shutdown.patch` ([#23](https://github.com/okafrancois/circa/issues/23)).

`UserScriptListener` defers every navigation that matches a content-script pattern until each
profile has reported its user scripts loaded. Upstream (unchanged on Chromium `main`) only
removes the registry observation in `OnShutdown`, so a profile destroyed before that report
left an entry that never became ready, and matching navigations of every remaining profile
waited forever. The delta implements the header's declared `ProfileDestroyed`: it erases the
profile's entry and re-evaluates readiness, which resumes navigations deferred only by that
profile. The destroyed profile's own throttles are already gone with its WebContents (the
listener keeps weak pointers). A unit test (`ProfileDestroyedBeforeScriptsReady`) covers it.

The test-only `content/public/test/mock_navigation_throttle_registry` follows the fork's
`AddThrottle(throttle, first)` signature so that the unit test compiles (it is not linked
into the framework). No mojom, build file, CEF or public API change; same release and
dependency pins as r25.

Rebuild on the r25 tree:

```sh
python3 scripts/cef-engine-r26-build.py --apply --jobs 8
```

The builder checks the complete r25 source state, applies the delta under the shared source
lock, verifies the v19 markers, the passkey group and the release version in the exported
framework, and refuses to replace r26.
