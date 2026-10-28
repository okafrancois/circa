# Distribution

Orbit ships through [GitHub Releases](https://github.com/okafrancois/orbit-browser/releases) in `okafrancois/orbit-browser`. Each release provides a notarized DMG for first installs, a ZIP archive, delta updates and a signed Sparkle appcast at `releases/latest/download/appcast.xml`.

- Bundle identifier: `io.github.okatech.orbit`. Data lives in `~/Library/Application Support/Orbit/`.
- Signing: Developer ID Application (team 5Y39TTNCM7), hardened runtime, notarized and stapled. The signing identity stays stable across releases so secure storage remains accessible.
- Updates: Sparkle 2 with EdDSA signatures; checks at launch and hourly, silent download, install on quit. Build numbers strictly increase; published versions are never replaced.
- Releases are produced by `scripts/release.py` on the project's self-hosted runner when a `vX.Y.Z` tag is pushed. See [the release pipeline](pipeline.md).
- Private keys and signing credentials never enter this repository.

The project license is MIT, Copyright (c) 2026 Okatech. Preserve all dependency notices listed in `THIRD_PARTY_NOTICES.md`.
