# Native Web Store installer transfer ownership — R1 (prepared CEF source)

**Prepared source only; not built.** Stacked on unowned-tabs-r2's `BUILD.gn`.
Repairs review `71bae4dad` A1 at the native layer, replacing the bridge's
URL/MIME/document heuristic, which is removed (approved R2 keeps the ordinary
download flow for every item until this framework exists).

`CefDownloadManagerDelegateImpl` classifies each item once, at its first
browser association (`OnDownloadCreated` or `DetermineDownloadTarget`), with
`orbit::IsWebstoreInstallerTransfer`:

- `DownloadItem::GetDownloadSource() == EXTENSION_INSTALLER` — set only by
  `extensions::WebstoreInstaller::StartDownload` (`webstore_installer.cc:604`);
- forced target `<ExtensionsBrowserClient::GetUserDataDir()>/Webstore Downloads/*.crx`
  (absolute, no parent references), set at `webstore_installer.cc:592`;
- the item's browser context is the originating browser's own, not off the record;
- Chrome runtime style (unhandled means Chrome handling, not Alloy cancellation);
- secondary native comparison of the original URL with
  `extension_urls::GetWebstoreUpdateUrl()` (scheme/host/path only; no query
  parsing, no allocation proportional to the query).

Such items never reach the client's `CefDownloadHandler` (neither
`OnBeforeDownload` nor `OnDownloadUpdated`); `DetermineDownloadTarget` returns
false so Chrome's target determination keeps the forced target, hidden UI,
approval and CrxInstaller verification. The approval pointer is never read
(it is attached after the download starts). Every other download is unchanged.
The record is erased with the item (`OnDownloadDestroyed`).

Tests: `orbit_installer_downloads_unittest.cc` in `libcef_static_unittests`
(review counterexample: identical public facts, ordinary source → not owned;
forced target, context, style and URL refusals). Real-flag syntax of the
predicate, delegate and test TUs. Runtime gates: Store consent accept/cancel
with no shell save prompt or Downloads row; ordinary file and ordinary CRX
controls; in-flight installer at Quit.
