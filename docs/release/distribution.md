# Distribution

Orbit ships through [GitHub Releases](https://github.com/okafrancois/circa/releases) in `okafrancois/circa`. Each release provides a notarized DMG for first installs, a ZIP archive, delta updates and a signed Sparkle appcast at `releases/download/update-feed/appcast.xml`. The version release also retains its own `appcast.xml` for older installations.

- Bundle identifier: `io.github.okatech.orbit`. Data lives in `~/Library/Application Support/Orbit/`.
- Signing: Developer ID Application (team 5Y39TTNCM7), hardened runtime, notarized and stapled. The signing identity stays stable across releases so secure storage remains accessible.
- Updates: Sparkle 2 with EdDSA signatures; checks at launch and hourly, silent download, a sidebar restart card, and install on quit. Pending updates are checked against a fresh feed before presentation, restart or a normal quit; superseded installers are cancelled through Sparkle and replaced. A stale or unverifiable installer is cancelled on normal quit; a fresh check on the next launch retrieves the newest update. Build numbers strictly increase; published versions are never replaced.
- Releases are produced by `scripts/release.py` on the project's self-hosted runner when a `vX.Y.Z` tag is pushed. See [the release pipeline](pipeline.md).
- Private keys and signing credentials never enter this repository.

The project license is MIT, Copyright (c) 2026 Okatech. Preserve all dependency notices listed in `THIRD_PARTY_NOTICES.md`.

Website and mobile releases must never be marked latest; create them with `--latest=false`. Only browser version releases may be latest.

The repository was renamed from `okafrancois/orbit-browser` to `okafrancois/circa`. GitHub redirects the old name, which older installations still use for their feed. Never create a new repository named `orbit-browser`: it would break those redirects. The Sparkle signing key keeps its `orbit-browser` Keychain account name.
