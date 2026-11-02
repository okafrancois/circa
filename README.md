<p align="center"><img src="web/assets/favicon.svg" alt="Circa" width="88"></p>

# Circa

Circa is an independent macOS browser built with Swift and AppKit, powered by a maintained CEF/Chromium 156 engine. Your tabs live in a sidebar, your work in Spaces, and your browsing data stays in local profiles. No Circa account is required.

[Website](https://circa-alpha.vercel.app) · [Download for Mac](https://github.com/okafrancois/circa/releases/latest/download/Circa.dmg) · [Releases](https://github.com/okafrancois/circa/releases) · [Report an issue](https://github.com/okafrancois/circa/issues)

**Status: preview.** Circa ships signed, notarized releases with automatic updates. Features, website and extension compatibility, and performance are still evolving.

## Features

- Spaces, separate profiles, favorites, pinned tabs and folders.
- A Command Bar, Split View, Peek and Little Circa for quick browsing.
- Space themes, browsing history, downloads and a tab archive.
- Chromium extensions and browser imports. Compatible internal Manifest V3 extensions can be imported into fresh profiles; their settings, stored data and sign-ins are not transferred.
- Optional AI using supported providers already available on your Mac: Codex, Claude Code and Apple's on-device model. AI starts off and requires a configured, available provider.
- An AI sidebar, Ask in Find, writing help, link summaries, tab organization, reusable Skills and staged CSS/JavaScript Boosts.
- Browser Errands with a fresh approval for each proposed page action. Stop keeps the task's tabs.

## Installation and updates

1. Download [Circa.dmg](https://github.com/okafrancois/circa/releases/latest/download/Circa.dmg), or choose a version from [GitHub Releases](https://github.com/okafrancois/circa/releases/latest).
2. Open it and drag Circa to Applications. Builds are signed with a Developer ID and notarized by Apple.
3. To make Circa your default browser, choose it in System Settings › Desktop & Dock › Default web browser.

Circa checks for updates at launch and every hour, downloads them in the background and offers a restart when ready. Use Circa › Check for Updates… to check manually. Updates are signed with an EdDSA key and verified by [Sparkle](https://sparkle-project.org). Supported systems: macOS 15 or later on Apple Silicon.

## Build

Prerequisites: Apple Silicon, macOS 15 or later, Xcode with Swift 6 and its command-line tools, Git and Python 3.10 or later. The Chromium application also requires CMake 3.26+, Ninja and a matching prebuilt, patched CEF 156 distribution with its sandbox and compiled wrapper library. Engine binaries and signing credentials are not included.

For a source compilation check without CEF:

```sh
swift build --package-path native
```

This builds the shared modules and the WebKit development executable; the Chromium application is built separately with CMake. Do not treat the SwiftPM executable as the Chromium product.

See [building Circa](docs/release/building.md) for the Chromium configuration and packaging requirements, and [architecture](docs/native-port/orbit-architecture.md) for the module layout. Tests use synthetic data and a mock Keychain; building does not install an app or change your default browser. Internal modules, tooling paths and bundle identifiers retain the Orbit name.

## Repository layout

`native/`, `scripts/`, `release/`, `docs/` and `.github/` stay at the repository root because browser builds, worktrees and the self-hosted release runner depend on those paths. New website and mobile projects live in `web/` and `mobile/`. Their releases use `web-vX.Y.Z` and `mobile-vX.Y.Z` tags, always pass `--latest=false`, use workflows filtered to their own folder, and never run on the self-hosted browser runner.

## Source and licensing

This repository contains the native application, tests, engine patch sources, build and release tools. Browser data and credentials are never part of it.

Circa's original code is licensed under the [MIT License](LICENSE), Copyright (c) 2026 Okatech. Dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
