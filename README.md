<p align="center"><img src="docs/brand/orbit/logo.svg" alt="Orbit" width="88"></p>

# Orbit

Orbit is an independent macOS browser built with Swift and AppKit, with a maintained CEF/Chromium 156 engine fork. Spaces, a vertical sidebar, profiles, pinned tabs, Split View and Peek organize browsing around your work. Browser state is stored locally; a cloud account is not required.

**Status: development preview.** Features, compatibility and performance are still being validated. This is not a stable release or a claim of complete feature equivalence. Some build targets, bundle identifiers and resources retain earlier internal names while the Orbit identity is integrated.

The target application bundle identifier is `io.github.okatech.orbit`; its migration is a separate release task.

The identity uses Ink `#0D0B1E`, Chalk `#F5F0E8`, Halo `#9D8CFF`, Dawn `#FF7A59` and Sun `#FFC56E`. The small mark above uses the ring and satellite geometry from the Orbit identity study.

## Installation and updates

Signed preview downloads will be published through [GitHub Releases](https://github.com/okafrancois/orbit-browser/releases). No public installer is available from this source snapshot. Once a signed release is available, its release notes will describe installation and supported macOS versions.

Automatic updates using Sparkle are planned. The public update feed, signing, notarization and end-to-end update validation are not ready in this snapshot. Do not expect automatic updates yet. See [distribution status](docs/release/distribution.md).

## Build

Prerequisites: Apple Silicon, macOS 15 or later, Xcode with Swift 6 and its command-line tools, Git and Python 3.10 or later. The Chromium application also requires CMake 3.26+, Ninja and a matching prebuilt, patched CEF 156 distribution with its sandbox and compiled wrapper library. Engine binaries and signing credentials are not included.

For a source compilation check without CEF:

```sh
swift build --package-path native
```

This builds the shared modules and the WebKit development executable; the Chromium application is built separately with CMake. Do not treat the SwiftPM executable as the Chromium product.

See [building Orbit](docs/release/building.md) for the Chromium configuration and current packaging limitations, and [architecture](docs/native-port/orbit-architecture.md) for the module layout. Tests use synthetic data and a mock Keychain; building does not install an app or change your default browser.

## Source and licensing

This snapshot contains the native application, tests, engine patch sources and selected build tools. Private investigation material and browser data are kept outside the public source tree.

Orbit's original code is licensed under the [MIT License](LICENSE), Copyright (c) 2026 Okatech. Dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
