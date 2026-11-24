# action.openPopup() in hosted Browsers (r27)

r27 is the complete r26 composition (the r21 unions and the r22, r23, r24 and r26 deltas on
Chromium **158.0.8127.65**, CEF 8127, side API v19) plus one Chromium and one CEF delta
([#25](https://github.com/okafrancois/circa/issues/25)).

`chrome.action.openPopup()` (and `browserAction.openPopup()`) shows the popup through Chrome's
Views toolbar container. A hosted logical Browser has neither a toolbar nor an
`ExtensionsContainer`, so the call failed with "Browser window has no toolbar." before any popup
host was created, and extensions that open their popup from page content (an inline unlock
button that messages the service worker) did nothing.

- `chromium-delta.patch` hooks `OpenPopupInBrowser` only: for a hosted Browser it returns the
  CEF service's answer; every other Browser keeps Chrome's toolbar path. Chrome's checks before
  it are unchanged (an active window, a popup visible on the active tab, `windowId` resolution in
  the extension's profile).
- `cef-delta.patch` adds `orbit_action_popup.{h,inc}` and includes the service after the toolbar
  services. A request is refused, with Chrome's generic "Failed to open popup.", for a private
  window, a tab other than the shell's published selection, or while a popup of that window is
  up (Chrome's toolbar shows one at a time). Otherwise the embedder answers synchronously with
  the action anchor it registered for the selected tab, or with none for the engine-owned
  detached window of side API v19. The popup is the action's genuine `ExtensionViewHost` in the
  existing anchored bubble or detached window, under the same leases and cancellation as a
  native action. The action itself never runs: no `action.onClicked`, no activeTab grant. The
  promise resolves once the popup is on screen and rejects if it closes first.
- Two functions are exported and resolved by name, like the toolbar services:
  `orbit_cef_extension_popup_observe(handler, context)` and
  `orbit_cef_extension_open_popup(request, anchor, invocation, surface, profile, epoch)`.
  The side API table is unchanged; an embedder without them keeps the previous behavior.

The Chromium file is not touched by any earlier patch, and the CEF delta appends to
`orbit_cef_api.mm` outside the r24 delta's hunks, so every earlier delta still checks
independently. No mojom, build file or public CEF API change; same release and pins as r26.

Rebuild on the r26 tree:

```sh
python3 scripts/cef-engine-r27-build.py --apply --jobs 8
```

The builder checks the complete r26 source state, applies the deltas under the shared source
lock, verifies the exported functions, the v19 markers, the passkey group and the release
version in the exported framework, and refuses to replace r27.
