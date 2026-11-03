# Contributing to Circa

Thanks for taking a look. Circa is a native Mac browser: a Swift and AppKit shell on a maintained Chromium engine. It is preview software, so bug reports from real use help as much as code.

## Report a problem

[Open an issue](https://github.com/okafrancois/circa/issues) with:

- your Circa version (Circa › About Circa) and macOS version
- what you did, what you expected, and what happened
- the site address, if the problem is specific to one site
- the extension name and version, if an extension is involved

Please remove anything private from screenshots and logs. For a security problem, don't open a public issue: use [private vulnerability reporting](https://github.com/okafrancois/circa/security/advisories/new).

## Find something to work on

- [Good first issues](https://github.com/okafrancois/circa/labels/good%20first%20issue) don't need the Chromium engine.
- [Help wanted](https://github.com/okafrancois/circa/labels/help%20wanted) issues are larger.
- For a new feature or a big change, open an issue first so we can agree on the approach.

## Set up

You need an Apple Silicon Mac with Xcode 27 (Swift 6.4 and the macOS 27 SDK), Git and Python 3.10+.

Most of the code builds and tests without the Chromium engine:

```sh
git clone https://github.com/okafrancois/circa.git
cd circa
swift build --package-path native
swift test --package-path native --filter BrowserCoreTests
```

This compiles the shared modules and a WebKit development executable. A Swift-only build doesn't validate Chromium behavior.

To build the full product, you also need CMake 3.26+, Ninja and the pinned engine. See the [build guide](docs/release/building.md), and [`release/engine.json`](release/engine.json) for the current engine archive and its hashes.

## Find your way around

| Location | What's there |
|---|---|
| `native/Sources/BrowserCore/` | Browser model, profiles, Spaces, persistence, imports |
| `native/Sources/BrowserShell/` | Engine-independent sessions, commands and resources |
| `native/Sources/BrowserEngine/` | Engine contract and surface lifecycle |
| `native/Sources/Orbit/` | AppKit windows, sidebar, menus, Command Bar, Peek, Split View |
| `native/OrbitChromium/` | CEF bridge, Chromium adapter and packaging |
| `native/Tests/` | Native tests with invented data |
| `web/` | The static website |

The code still uses the project's former internal name, Orbit, in modules, tools and bundle identifiers. The [architecture notes](docs/native-port/orbit-architecture.md) go deeper.

## Send a pull request

1. Keep it focused on one change, and explain what it does and how you tried it.
2. Add or update a targeted test when you change behavior.
3. Run the tests for what you touched. Include `LocalizationTests` whenever you add user-facing text:

   ```sh
   swift test --package-path native --filter 'BrowserCoreTests|LocalizationTests'
   ```

4. For a visible change, attach a screenshot or a short recording.
5. Run the public repository check:

   ```sh
   python3 scripts/check-public-hygiene.py
   ```

A few rules apply to every change:

- Code, comments, tests, commit messages and docs are written in English. User-facing strings go through `uiText` so they can be translated.
- Tests use invented data and the mock Keychain. Never run them against a real browser profile.
- Don't commit personal browsing data, secrets, certificates, engine binaries or build output.
- Describe behavior in neutral terms and don't copy another browser's assets. The public repository check enforces the naming rules.

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
