<p align="center"><img src="docs/brand/orbit/logo.svg" alt="Orbit" width="88"></p>

# Orbit

Orbit is an independent macOS browser built with Swift and AppKit, with a maintained CEF/Chromium 156 engine fork. Spaces, a vertical sidebar, profiles, pinned tabs, Split View and Peek organize browsing around your work. Browser state is stored locally; a cloud account is not required.

**Status: preview.** Orbit is used daily and ships signed, notarized releases with automatic updates. Features, compatibility and performance keep evolving between releases.

## Installation and updates

1. Download the latest `Orbit-x.y.z.dmg` from [GitHub Releases](https://github.com/okafrancois/circa/releases/latest).
2. Open it and drag Orbit to Applications. Builds are signed with a Developer ID and notarized by Apple.
3. To make Orbit your default browser, choose it in System Settings › Desktop & Dock › Default web browser.

Orbit checks for updates at launch and every hour, downloads them in the background and installs them the next time it quits. Use Orbit › Check for Updates… to update right away. Updates are signed with an EdDSA key and verified by [Sparkle](https://sparkle-project.org). Supported systems: macOS 15 or later on Apple Silicon.

## Build

Prerequisites: Apple Silicon, macOS 15 or later, Xcode with Swift 6 and its command-line tools, Git and Python 3.10 or later. The Chromium application also requires CMake 3.26+, Ninja and a matching prebuilt, patched CEF 156 distribution with its sandbox and compiled wrapper library. Engine binaries and signing credentials are not included.

For a source compilation check without CEF:

```sh
swift build --package-path native
```

This builds the shared modules and the WebKit development executable; the Chromium application is built separately with CMake. Do not treat the SwiftPM executable as the Chromium product.

See [building Orbit](docs/release/building.md) for the Chromium configuration and current packaging limitations, and [architecture](docs/native-port/orbit-architecture.md) for the module layout. Tests use synthetic data and a mock Keychain; building does not install an app or change your default browser.

## Repository layout

`native/`, `scripts/`, `release/`, `docs/` and `.github/` stay at the repository root because browser builds, worktrees and the self-hosted release runner depend on those paths. New website and mobile projects live in `web/` and `mobile/`. Their releases use `web-vX.Y.Z` and `mobile-vX.Y.Z` tags, always pass `--latest=false`, use workflows filtered to their own folder, and never run on the self-hosted browser runner.

## Source and licensing

This repository contains the native application, tests, engine patch sources, build and release tools. Browser data and credentials are never part of it.

Orbit's original code is licensed under the [MIT License](LICENSE), Copyright (c) 2026 Okatech. Dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
