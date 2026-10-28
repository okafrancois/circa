# Chrome-created tabs offered to the embedder — R1 (superseded by unowned-tabs-r2)

**Superseded:** review `71bae4dad` found B1/B2 in this revision; the union uses
`unowned-tabs-r2`. Kept unchanged below as review history.

**Prepared CEF source only; not built, not an approved framework.** Apply after
modal-dialog-host-r2's CEF patch (its `BUILD.gn` output is this patch's input)
and with the v4 extensions patch; `scripts/check_extensions_engine_union.py`
checks the whole order on private copies.

## Defect (source)

`ChromeBrowserDelegate::SetAsDelegate` (ENG-X2 branch, `chrome_browser_delegate.cc`)
creates the CEF host of a tab that Chrome inserts by itself in an Orbit logical
Browser — an extension's `chrome.tabs.create`, an options page opened in a tab
(`ExtensionTabUtil::OpenOptionsPage`), onboarding after an install — with
`client = nullptr` and no parent view. The tab loads, counts for the
extension APIs, but has no Orbit surface: the user never sees it.

## Change

- `orbit_unowned_tabs.{h,mm}` (libcef_static): `OfferUnownedTab` gives the
  embedder the window token, profile path, visible URL, tab index and
  activation; an answer sets the client, the parent view, the window's current
  generation and the tab index of the creation parameters, so the tab becomes
  an ordinary hosted tab of that surface (same path as an accepted popup).
- `orbit_unowned_tabs_entry.cc` (framework sources, DLL side of the C API): the
  exported `orbit_cef_set_unowned_tab_handler` and the only C→C++ client
  adoption (`CefClientCToCpp_Wrap`), as `cef_browser_host_create_browser` does.
- `orbit_unowned_tabs_api.h`: the C contract, identical to the bridge's
  `native/OrbitChromium/Bridge/OrbitUnownedTabsApi.h`
  (`scripts/test_unowned_tabs_contract.py`).

The side-API struct `orbit_cef_api_t` (v4, 176 bytes) is unchanged; the bridge
resolves the new symbol optionally, so frameworks without this patch keep the
previous behaviour. `windows.create` and other new Browsers still use Chrome's
own window factory (X2-EXT-WINDOW-CREATE), outside this patch.

## Checks and limits

Real-flag `-fsyntax-only` of `orbit_unowned_tabs.mm`, `chrome_browser_delegate.cc`
and `orbit_unowned_tabs_entry.cc` through a VFS overlay (`ninja -t commands`
only), with an injected `static_assert` proving the overlay is compiled. No CEF
unit test is added: the embedder side is covered by the bridge exact-body test
(`scripts/test_unowned_tab_adoption.py`), the stub-bridge adapter check and the
shell adoption suite. GN `check` of the new framework-side include is not run.
Runtime acceptance (an extension's `tabs.create`, an options page in a tab,
foreground/background, two profiles, close and restart) is in the lot report.
