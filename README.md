<p align="center">
  <img src="web/assets/favicon.svg" alt="Circa logo" width="128" height="128">
</p>

<h1 align="center">Circa</h1>

<p align="center">
  A native Mac browser with your tabs in a sidebar and your work in Spaces.<br>
  Free and open source. Built with Swift, AppKit and Chromium.
</p>

<p align="center">
  <a href="https://github.com/okafrancois/circa/releases/latest/download/Circa.dmg"><b>Download for macOS</b></a> ·
  <a href="https://circabrowser.com">circabrowser.com</a> ·
  <a href="https://github.com/okafrancois/circa/releases">What's new</a> ·
  <a href="https://github.com/okafrancois/circa/issues">Report an issue</a>
</p>

<p align="center">
  <a href="https://github.com/okafrancois/circa/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/okafrancois/circa?label=release"></a>
  <img alt="macOS 15+, Apple silicon" src="https://img.shields.io/badge/macOS-15%2B%20%C2%B7%20Apple%20silicon-lightgrey">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/okafrancois/circa"></a>
</p>

Keep everyday sites close, separate projects into Spaces, and open two pages side by side. The Command Bar brings tabs, history and browser actions together. Peek and Little Circa give you a quick look without losing your place.

**Preview software.** Circa ships signed, notarized releases with automatic updates. Features, website and extension compatibility, and performance are still evolving.

## Install

1. [Download Circa for Mac](https://github.com/okafrancois/circa/releases/latest/download/Circa.dmg).
2. Open the DMG and drag Circa to Applications.
3. To make it your default browser, select Circa in System Settings › Desktop & Dock › Default web browser.

Requires **macOS 15 or later and Apple Silicon**. Releases are Developer ID signed and notarized by Apple. Circa downloads updates in the background and offers a restart when ready. You can also use Circa › Check for Updates… . Updates are verified by [Sparkle](https://sparkle-project.org).

## Make room for your work

| Feature | What it does |
|---|---|
| Spaces and profiles | Separate projects and browsing sessions |
| Favorites, pinned tabs and folders | Keep the sites you return to within reach |
| Command Bar | Open pages, find tabs and history, and run browser actions |
| Split View | Work with pages side by side |
| Peek and Little Circa | Take a quick look in a preview or a small window |
| Themes | Give each Space its own appearance |
| Library | Return to history, downloads and archived tabs |
| Chromium extensions | Use compatible browser extensions |
| CSS and JavaScript Boosts | Customize sites with edits you control |

## Optional AI

AI starts **off**. Choose an available provider in Settings: Codex, Claude Code, or Apple's on-device model on a supported Mac. No Circa account is required; external providers use their own accounts and availability limits.

- Ask about a chosen page in the sidebar, or use Ask in Find.
- Get writing help and link summaries, tidy tab titles and downloads, and organize Today tabs.
- Save reusable prompts as Skills and generate staged CSS or JavaScript Boosts.
- Start a Browser Errand from the Command Bar. Each proposed page action needs a fresh **Allow Once**; Stop keeps the task's tabs.

Generated edits are reviewed before applying. Page access follows your AI settings and site exclusions.

## Bring your browsing with you

Use Circa's import commands to move supported data from another browser into a new profile. Available categories depend on the source browser and its export format. Review the import summary before proceeding.

Compatible internal Manifest V3 extension packages can be restored into fresh profiles. Extension settings, local storage, sign-ins and private-browsing grants are not transferred. Safari and Firefox extensions are not imported.

## Keyboard

A few everyday shortcuts; the full bindings are available in Settings › Shortcuts.

| Shortcut | Action |
|---|---|
| <kbd>⌘</kbd> <kbd>T</kbd> | Open the Command Bar for a new tab |
| <kbd>⌘</kbd> <kbd>L</kbd> | Edit the current URL |
| <kbd>⌘</kbd> <kbd>W</kbd> | Close the current tab |
| <kbd>⌘</kbd> <kbd>D</kbd> | Pin or unpin a tab |
| <kbd>⌘</kbd> <kbd>S</kbd> | Show or hide the sidebar |

## Your data

Circa does not require a browser account. Local profiles hold your browsing state; optional iCloud organization sync is controlled in Settings. Passwords and cookies use the Chromium store with macOS Keychain-backed encryption.

AI is optional. When you request an AI feature, the selected provider processes the context permitted by your settings. An external provider's own data policies apply.

## Build from source

Use an Apple Silicon Mac with macOS 15+, Xcode with Swift 6, Git and Python 3.10+. To compile the shared modules and the WebKit development executable:

```sh
swift build --package-path native
```

The Chromium product is built separately with CMake 3.26+, Ninja and a matching patched CEF 156 distribution. Engine binaries and signing credentials are not included. See the [build guide](docs/release/building.md), [architecture](docs/native-port/orbit-architecture.md) and [release pipeline](docs/release/pipeline.md).

Tests use synthetic data and a mock Keychain. Internal modules, tooling paths and bundle identifiers retain the Orbit name. Browser code lives in `native/`, release tools in `scripts/` and `release/`, and the static website in `web/`.

## License

[MIT](LICENSE), Copyright (c) 2026 Okatech. Dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
