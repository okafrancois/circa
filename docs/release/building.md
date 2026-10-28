# Building Orbit

## Shared Swift code

Use an Apple Silicon Mac running macOS 15+ with Xcode and Swift 6. Select Xcode's developer directory and accept its license using the usual Xcode setup. Python 3.10+, Git, CMake 3.26+ and Ninja are needed for the Chromium build tools.

```sh
swift build --package-path native
```

SwiftPM builds the shared modules, import tools and a WebKit development executable. The product Chromium build is a separate CMake project. No application is launched or installed by this compilation check.

## Chromium product

Obtain a prebuilt macOS ARM64 CEF 156 distribution from the maintained engine fork, including CEF's CMake files, headers, framework, sandbox archive and the matching `libcef_dll_wrapper.a`. A stock CEF SDK does not supply the product's patched extension and hosted-tab APIs. The source patches and pins are under `native/OrbitChromium/cef-patches/`; `scripts/cef-engine-extensions-build.py` and `scripts/orbit-chromium-x2.py` preserve the engine-build workflow.

There is no public engine download attached to this initial snapshot. Do not substitute a random CEF build or disable input checks. The engine producer must supply the matching hashes and source revision. With those inputs, configure from the repository root:

```sh
cmake -S native/OrbitChromium -B native/OrbitChromium/build/public -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCEF_ROOT="$ORBIT_CEF_ROOT" \
  -DCEF_WRAPPER_LIBRARY="$ORBIT_CEF_WRAPPER" \
  -DCEF_WRAPPER_SHA256="$ORBIT_CEF_WRAPPER_SHA256" \
  -DCEF_FRAMEWORK_SHA256="$ORBIT_CEF_FRAMEWORK_SHA256" \
  -DCEF_SOURCE_COMMIT="$ORBIT_CEF_SOURCE_COMMIT" \
  -DCEF_VERSION_HEADER_SHA256="$ORBIT_CEF_VERSION_HEADER_SHA256"
cmake --build native/OrbitChromium/build/public --target package_orbit_app
```

The `ORBIT_CEF_*` variables above are local build inputs, not credentials. Their values must come from one matching engine distribution. The unsigned output retains the internal path `native/OrbitChromium/build/public/product/Orbit.app`.

The product currently requires stable signing identity configuration (`ORBIT_STABLE_SIGNING_ROOT`, the certificate SHA-1) and signed packaging before normal launch. An unsigned successful build is not an installable Orbit release. Public signing/notarization and the Orbit bundle-name migration remain release work. Never bypass product admission or use ad hoc signing on an existing real profile.

The retained packaging scripts describe development workflows and may refer to excluded historical evidence. They are not a public installer. Do not run the retired Live/update installers. Keep engine binaries, certificates, private keys, profiles and build outputs outside version control.

## Tests and third-party notices

Tests use invented sessions and mock secure storage. Model tests can be selected with `swift test --package-path native --filter BrowserCoreTests`. The Chromium integration additionally needs the matching engine and synthetic smoke bundle. On a shared host, serialize full Swift test suites with `lockf`; a Swift-only build does not validate Chromium behavior.

The Public Suffix List's existing Mozilla license is retained in `native/ThirdParty/publicsuffix/`. CEF/Chromium and their dependencies have separate redistribution obligations. A binary release must preserve the notices accompanying its engine distribution.
