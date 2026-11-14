# Supported milestone engine (r21)

r21 moves the complete r20 union from the 156 branch (CEF 8078) to the supported
CEF **8127** branch and Chromium **158.0.8127.37**. The side API stays v18.

- `cef.patch`: the fork on top of CEF 8127 head `8c29be24`. It carries every fork
  commit up to r20 (side API v18, native hosted windows, extension hosts, unowned
  tabs, password and permission bridges, lifecycle, purge, preconnect, developer
  tools hosting, popup lookup), the fork's Chromium patches in `patch.cfg`, the
  file dialog mode with recomputed API hashes, and the Chromium 158 adaptations.
- `chromium.patch`: the direct Chromium union (40 files): developer tools hosting,
  popup cancellation, AppKit modal parents, navigation intent, notification routing,
  picture-in-picture overlay, password and isolated-world changes.

Port notes: CEF 8127 pins 158.0.8127.18; two upstream patches (`views_widget`,
`views_1749_2102_3330`) were rebased onto .37. Chromium 158 removed two
`BrowserWindow` methods, renamed `WindowOpenDisposition` values and moved the
predictor traffic annotation. The extension install bubble fix is upstream now.
Chromium 158 also refuses page fullscreen from a view without focus
(`kSuppressFullscreenFromUnfocusedView`); this hardening is kept.

The distribution builds `libcef_dll_wrapper` with `api_version=15600`, the API
version of the application (`native/OrbitChromium/CMakeLists.txt`). The default
experimental API on 8127 adds client slots (for example `get_input_handler`) that
the application does not implement; a mismatched wrapper crashes on input events.

Reproduce:

```sh
python3 scripts/cef-engine-milestone-migrate.py --version 158.0.8127.37 \
  --cef-source <fork git> --cef-ref orbit/8127 --cef-commit <commit> --logs <fresh>
git -C .tools/chromium-fork/chromium/src apply "$PWD/native/OrbitChromium/cef-patches/engine-r21/chromium.patch"
python3 scripts/cef-engine-r21-build.py --jobs 8
```

The migration backs up every working diff first. After a first patcher run, later
runs report overlapping patches as failed although they are applied; validate the
series from a pristine tree instead. The builder checks the Chromium, dependency
and CEF tree pins and the applied Chromium union, and refuses to replace r21.
Weekly security updates use `cef-engine-security-update.py` on the 158.0.8127 branch.
