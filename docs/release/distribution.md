# Preview distribution

Orbit is a development preview. The initial public source snapshot does not include a downloadable engine or a signed installer. Public builds are intended for GitHub Releases in `okafrancois/orbit-browser`.

Before the first binary release, finish the Orbit bundle branding, produce the matching patched CEF distribution, sign and notarize the app and its helpers, and test installation using a synthetic profile. Keep a stable signing identity across releases so secure storage remains accessible.

Sparkle automatic updates are planned. The signed appcast, update-signing configuration, release hosting and a real upgrade/rollback test are still required. No active public update feed is promised by this snapshot. Private keys and signing credentials must stay outside this repository.

The project license is MIT, Copyright (c) 2026 Okatech. Preserve all dependency notices listed in `THIRD_PARTY_NOTICES.md`. The target bundle identifier is `io.github.okatech.orbit`; its code/signing migration remains a separate lot. Private investigation material belongs under the ignored `lab/` directory, which must never be staged or published. Remaining former-product identifiers and investigation references must be removed before publication, except the user-facing import command.
