# Extension popup latency candidate

Not compiled or runtime validated. This incremental patch is deliberately not
wired into an engine build or the approved distribution list.

Native action popups are ExtensionViewHost WebContents without a CefBrowserHost.
The renderer synchronously asks GetNewBrowserInfo for its main frame. Without
an immediate excluded-frame response it waits for the 2,000 ms fallback timer.
Recognize only unowned kExtensionPopup contents in IsExcludedFrameHost; keep
CEF-owned extension tabs and the existing popup authorization unchanged.

Validate without modifying the shared checkout:

```sh
python3 scripts/check_popup_latency_patch.py --cef-source /path/to/chromium/src/cef
```

The manifest pins the incremental working-file input and output. An engine owner
must integrate the patch into the next distribution, compile, and rerun the
synthetic popup latency and popup cancellation checks before admission. Do not
reduce the global timeout or show unloaded contents as a substitute.

The product probe accepts `extension-controls` / `pinned-popup` with
`latency: "true"` and an explicit `extensionID`. It samples first window creation
and visibility at 10 ms intervals and records dispatch-return timing. Setting
ORBIT_EXTENSION_DIAGNOSTICS also enables native dispatch timestamps and writes
Tracing.dataCollected events to Chromium/popup-trace.jsonl in mock-storage runs.
The latency command starts and ends tracing. These are diagnostic measurements,
not a change to production popup behavior.

Generate fixtures with `python3 scripts/popup-latency-fixtures.py /tmp/popup-fixtures`.
The heavy fixture has about 4 MB of executable source and messages an MV3 worker;
neither fixture has an artificial delay. The command shortcut is Command-Shift-Y
on macOS. Independently verify worker/process termination for strict cold trials.
