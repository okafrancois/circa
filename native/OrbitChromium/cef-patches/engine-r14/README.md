# Native diagnostics and extension preferences

Chromium 156.0.8078.84 on the maintained 8078 branch. `source.json` pins the
release and populated dependency checkouts. `cef.patch` is additive to the complete
r13 CEF/Orbit union. Earlier distributions and side-API prefixes remain available.

Inspect upstream DEPS before `scripts/cef-engine-security-update.py`. Disabled
conditional dependencies with no Git checkout are skipped. For an interrupted
update, use a fresh logs directory and `--dependency-baseline <original-revision>`
so remaining Git rolls are still discovered after Chromium itself has advanced.
`scripts/cef-engine-r14-build.py` builds the single shared incremental cache under
the source lock, nice 10, Ninja at most eight jobs, and exports a separate flavor.

Side API v16 appends `diagnostic_capabilities`, `task_manager`, `trace_begin`,
`trace_end`, `extension_options_open` and `extension_incognito_set`. Capability
bits are 1 task manager, 2 tracing, 4 options and 8 incognito preference. All calls
and callbacks run on UI. Calls returning zero are refused and never call back.
Accepted tracing operations callback once; borrowed path bytes expire on return.
Tracing is process-wide, not profile-filtered. One persistent profile owns a session
until end completion; await begin before end and stop using a live surface in that
profile before engine shutdown.
The shell supplies a new destination below that profile's data root with an existing
parent. Traversal, resolved symlink escapes and existing destinations are refused.

Extension inventory adds optional `hasOptionsPage`, `optionsURL`, `canAllowIncognito`
and `isAllowedInIncognito`. Missing fields mean an older backend. Options opening
uses the installed enabled extension's native options route in the caller's browser;
it never accepts a caller-provided URL. Incognito writes use Chromium's native
preference utility, including reload/sync behavior, and reject unsupported extensions.
This only changes a persistent profile preference. Supporting extensions in a separate
ephemeral private engine would additionally require a related off-the-record context,
extension service routing and lifetime/isolation qualification; it is outside this API.

Swift: `BrowserEngineSurface.nativePageServices` exposes `supportsTaskManager`,
`openTaskManager()`, `supportsTracing`, `beginTracing(categories:)` and `endTracing(to:)`.
`BrowserExtensionHost` exposes `supportsOptionsPages`, `openOptions(extensionID:on:)`,
`supportsIncognitoPreference` and `setAllowedInIncognito(_:extensionID:in:)`.
No visible shell controls or implicit recording are added.

Qualification: `scripts/check_cef_security_api.py` checks real v1-v16 table prefixes,
rejecting v0/v17. `EngineBinaryCompatibilityTests.cc` checks typed function pointers.
The security and weekly smoke scripts exercise confined mock-Keychain bundles with
loopback or synthetic extension fixtures and bounded GUI leases.
