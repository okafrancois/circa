# Orbit native sources

The Swift 6 package targets macOS 15+. `swift build --package-path native` compiles the shared modules and the WebKit development executable, still named `Orbit` internally. It does not compile the CEF application.

The Chromium product uses `OrbitChromium/CMakeLists.txt`, the bridge and adapter in that directory, and the same application sources. It requires an external prebuilt, patched CEF 156 framework, sandbox and wrapper library. Engine patches are in `OrbitChromium/cef-patches/`.

See [build instructions](../docs/release/building.md) and [architecture](../docs/native-port/orbit-architecture.md). Existing historical README files in engine subdirectories describe individual development targets, not public installation instructions.

Tests contain synthetic profiles, URLs and credentials. Automatic tests must use synthetic roots and a mock Keychain; do not point them at an existing browser profile. Full Swift test runs on a shared development host should be serialized with `/usr/bin/lockf -k /tmp/arcy-native-full-suite.lock swift test --package-path native`.
