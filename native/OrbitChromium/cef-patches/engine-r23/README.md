# System passkeys (r23)

r23 is the complete r22 composition (CEF 8127, Chromium **158.0.8127.37**, side API v18,
`engine-r21/cef.patch`, `engine-r21/chromium.patch` and
`engine-r22/os-crypt-owned-directory.patch` unchanged) plus one Chromium change,
`system-passkeys.patch`. No header, Mojo or exported API changes.

1. **Platform (Touch ID) authenticator.** Chromium builds its keychain access group from
   `MAC_TEAM_IDENTIFIER_STRING "." MAC_BUNDLE_IDENTIFIER_STRING ".webauthn"`; with the CEF
   branding the team part is empty, so no signed browser could hold it. r23 compiles in
   `5Y39TTNCM7.io.github.okatech.orbit.webauthn`. The authenticator still requires the main
   executable to carry that `keychain-access-groups` entitlement
   (`crypto::apple::ExecutableHasKeychainAccessGroupEntitlement`); without it nothing changes.
   Release signing adds it only when `webauthn_keychain_access_group` is configured, admitted by
   the provisioning profile, and present verbatim in the engine binary.
2. **System passkey provider window.** `ChromeAuthenticatorRequestDelegate::ConfigureNSWindow`
   found the window only through a Views widget. A WebContents hosted directly in the
   embedder's AppKit views has none, so the provider never got a window. When there is no
   widget, r23 uses `WebContents::GetTopLevelNativeWindow()`, which is the `NSWindow` that
   contains the WebContents view. The provider itself still requires the managed browser
   entitlement (`fido::icloud_keychain::IsSupported()`), so unsigned or test bundles are
   unaffected.

Rebuild on the r22 tree:

```sh
python3 scripts/cef-engine-r23-build.py --apply --jobs 8
```

The builder checks the r21 pins and union, requires the r22 delta to be applied, applies the
r23 delta under the shared source lock, checks that the exported framework contains the group,
and refuses to replace r23.
