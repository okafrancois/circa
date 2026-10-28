# Chrome-created tabs offered to the embedder — R2 (prepared source, supersedes R1)

**Prepared source only; not built.** Replaces `unowned-tabs-r1` in the union
(`scripts/check_extensions_engine_union.py`); R1 is kept only as review history.
CEF part stacked on modal-dialog-host-r2's `BUILD.gn` output; Chromium part
pinned to the CEF-patched working `browser_navigator.cc`.

Review `71bae4dad` findings repaired:

- **B2 — foreground/URL/index from the real call order.** `chrome::Navigate`
  calls the Browser's creation hook (CEF `OnWebContentsCreated` →
  `SetAsDelegate` → `OfferUnownedTab`) right after `WebContents::Create`,
  before `LoadURLWithParams` and insertion (`browser_navigator.cc`
  CreateTargetContents). The patched CreateTargetContents now publishes the
  request's own URL, requested index and activation (`ADD_ACTIVE`, already
  normalized by `NormalizeDisposition`) in
  `chrome/browser/ui/navigator/orbit_navigate_intent.h` for the duration of
  that hook. `OfferUnownedTab` uses that intent when it belongs to the same
  Browser and contents, the tab strip once the tab is inserted, and reports
  activation **unknown (-1)** otherwise — never a guessed foreground. The C
  contract's `active` is tri-state (layout unchanged, 40 bytes).
- **B1 — CEF side.** Before the embedder call: weak pointers to the Browser
  and contents, the window generation and an adopter generation (changed by
  every `SetUnownedTabAdopter`). After it: Browser and contents alive, still
  the registered logical Browser of that window/profile, same generations.
  Otherwise nothing is published; the returned client is released, and the
  embedder's adopted client aborts its pending surface once on release.

Bridge and adapter halves of B1 are in `OrbitChromiumBridge.mm`
(`AdoptUnownedTab`, `~Client`) and `ChromiumBrowserEngine.adoptEngineCreatedTab`.
Tests: `scripts/test_unowned_tab_offer_order.py` (exact body from this patch,
R1 expected red), `scripts/test_unowned_tab_adoption.py`,
`ChromiumLifecycleTests --engine-tab-only`, `scripts/test_unowned_tabs_contract.py`.
Runtime gates: `chrome.tabs.create({active:true|false})`, options page in a tab,
onboarding after an install, source window close/profile switch while pending.
