# Browser-modal sheets and parented bubbles on registered AppKit parents — R1 (prepared source)

**Prepared source only; not built, not an approved framework.** Stacked on
[modal-dialog-host-r2](../../../../docs/native-port/extensions-outcome-r1-2026-10-27.md#engine-dialogs)
(commit `2f136c6785da724e2ddc93c5e048627de38f13f5`, independent review
`299484b1af22acdc6a418abcebdb0382e66f543a`). R2 must be applied first, both
its CEF and Chromium patches; this bundle has no CEF part.

## Defect, by call path (source inspection)

Chrome's extension prompts are browser-modal (`ui::mojom::ModalType::kWindow`)
Views dialogs parented to the tab's top-level native window:

- Store "Add …?" — `ShowExtensionInstallDialogImpl`
  (`chrome/browser/ui/views/extensions/extension_install_dialog_view.cc:104–109`)
  → `constrained_window::CreateBrowserModalDialogViews(dialog, parent)`.
- Remove confirmation and post-install "added" dialog —
  the uninstall dialog (`chrome/browser/ui/extensions/extension_uninstall_dialog_impl.cc:127`)
  and `ShowExtensionPostInstallDialog` (`extension_post_install_dialog.cc:187`) →
  `ShowDialog(parent, …)` (`extension_dialog_utils_views.cc:51–61`), which uses
  the toolbar `ExtensionsContainerViews` when it exists and otherwise
  `constrained_window::ShowBrowserModal` → the same widget creation.

On macOS such a dialog is a sheet of its Chromium parent
(`NativeWidgetNSWindowBridge::IsWindowModalSheet()`), and constrained-window
positioning is disabled for it (`constrained_window_views.cc:359–363` of the CEF-patched input). An Orbit
window is an ordinary NSWindow: `NativeWidgetMacNSWindowHost::GetFromNativeView`
finds no parent, R2's adapter accepts only `kChild`, and
`NativeWidgetMac::InitModalType` documents the fallback — "falling back to a
non-modal window". The dialog becomes an unparented top-level window at its
initial origin, non-movable (`setMovable:NO` for every `kWindow`), with no
parent ownership, positioning, move/resize/fullscreen following or close
teardown. This matches the three user screenshots (detached at the screen
corner, clipped, not draggable); the exact shipped-binary host value at this
call site was not observed.

## Change

- `AppKitModalDialogParent` gains a `kSheet` presentation. It never orders a
  child window; it defers a show the parent cannot present (hidden, minimized,
  other Space, closed) and begins it once through the bridge when the parent
  can. Parent close still closes the dialog synchronously.
- `NativeWidgetMac` selects the adapter for `kWindow` as well as `kChild` on a
  registered parent; `kWindow` uses `kSheet`. Unregistered parents keep the
  existing Chromium fallback. Reparenting stays `kChild`-only (browser-modal
  dialogs do not follow tab transfers).
- A non-modal `TYPE_BUBBLE` widget explicitly parented to a registered view —
  the v4 native extension action popup (`ExtensionPopup::ShowPopupWithNativeParent`
  sets `set_parent_window(contentView)`) — becomes an ordered child window
  (R2's `kChildWindow`). Unparented, it would be a free top-level window that
  does not follow the window and, in full screen, is not in the window's
  Space. Its close-on-deactivate (outside click/Escape) stays Chromium's.
- `NativeWidgetNSWindowBridge::IsWindowModalSheet()` accepts the sheet adapter;
  `ShowAsModalSheet()` uses its native parent. A deferred show cannot begin a
  sheet twice (`window_visible_` is set before the posted begin).

Chromium's own sheet code then owns presentation, focus, Escape/Cancel and
end-of-sheet teardown, exactly as for a Chromium parent. No extension, Store
or permission behaviour changes: consent stays in Chrome's own dialog.

## Verification and execution

```sh
python3 scripts/check_browser_modal_sheets_patch.py \
  --chromium-source <chromium>/src --r2-bundle <modal-dialog-host-r2 dir>
python3 -m unittest scripts/test_check_browser_modal_sheets_patch.py
```

Private checks run for this revision are listed in the report. Tests added:
three hidden `AppKitModalParentTest.Sheet*`/default-presentation cases and five
visible `ConstrainedWindowAppKitParentTest.BrowserModal*`/parent-close/
unregistered cases (sheet attachment, single begin after a hidden parent is
shown, movement with parent, Escape, parent close, fallback), plus two
parented/unparented bubble cases. The visible tests
show and activate synthetic windows: PM-coordinated session only.

Build requirements are R2's (frozen inputs, both R2 patches then this one,
authorized GN regeneration, bounded `cef` + test targets, immutable framework
and dSYM). Runtime acceptance is in the report's PM protocol.
