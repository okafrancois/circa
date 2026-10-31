// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbitLabNative",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "BrowserShell", targets: ["BrowserShell"]),
        .library(name: "BrowserEngine", targets: ["BrowserEngine"]),
        .library(name: "WebKitEngine", targets: ["WebKitEngine"]),
        .executable(name: "Orbit", targets: ["Orbit"]),
        .executable(name: "orbit-live-session", targets: ["OrbitLiveSessionTool"]),
        .executable(name: "orbit-import", targets: ["OrbitImportTool"])
    ],
    targets: [
        // Engine-independent model: identities, Spaces, sessions, downloads, zoom policy.
        .target(name: "BrowserCore"),
        .executableTarget(name: "OrbitLiveSessionTool", dependencies: ["BrowserCore"]),
        // Engine-independent coordinators generic over minimal surface protocols.
        .target(name: "BrowserShell", dependencies: ["BrowserCore"], resources: [.process("Resources"), .copy("Icons"), .copy("AppIcons")]),
        // Engine contract: surfaces, delegate events, profiles, capabilities. No engine imports.
        .target(name: "BrowserEngine", dependencies: ["BrowserCore", "BrowserShell"]),
        // Acceptance checks every engine adapter must pass; used by test targets only.
        .target(name: "BrowserEngineConformance", dependencies: ["BrowserCore", "BrowserEngine"]),
        // WebKit development/fallback backend. Only Orbit's composition root may import it.
        .target(name: "WebKitEngine", dependencies: ["BrowserCore", "BrowserShell", "BrowserEngine"]),
        .executableTarget(name: "Orbit", dependencies: ["BrowserCore", "BrowserShell", "BrowserEngine", "WebKitEngine"]),
        // Invented Orbit data (CORE-IMPORT): tests and visible lab validation only, never shipped in Orbit.
        .target(name: "OrbitImportSynthetic", dependencies: ["BrowserCore"]),
        // Offline Orbit import (dry run, apply, restore) while Orbit is closed.
        .executableTarget(name: "OrbitImportTool", dependencies: ["BrowserCore", "OrbitImportSynthetic"]),
        // AIFixtures: fake AI programs run from the source tree, never bundled.
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore", "OrbitImportSynthetic"], exclude: ["AIFixtures"]),
        .testTarget(name: "BrowserShellTests", dependencies: ["BrowserShell"]),
        .testTarget(name: "BrowserEngineTests", dependencies: ["BrowserEngine", "BrowserEngineConformance", "BrowserShell", "BrowserCore"]),
        .testTarget(name: "OrbitTests", dependencies: [
            "Orbit", "BrowserShell", "BrowserCore", "BrowserEngine", "BrowserEngineConformance", "WebKitEngine",
            "OrbitImportSynthetic"
        ]),
        // Native event dispatch needs a fresh NSApplication, separate from application lifecycle tests.
        .testTarget(name: "OrbitEventTests", dependencies: ["Orbit", "BrowserCore"]),
        // WebKit redispatch probes must not inherit application lifecycle tests' NSApplication state.
        .testTarget(name: "OrbitKeyboardTests", dependencies: [
            "Orbit", "BrowserCore", "BrowserShell", "BrowserEngineConformance", "WebKitEngine"
        ])
    ]
)
