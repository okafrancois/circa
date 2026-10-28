# Orbit architecture

Orbit targets macOS 15+ on Apple Silicon. The shell is Swift/AppKit and the product engine is a maintained CEF/Chromium 156 fork.

| Location | Responsibility |
| --- | --- |
| `native/Sources/BrowserCore/` | Browser model, profiles, Spaces, organization, local persistence and imports |
| `native/Sources/BrowserShell/` | Engine-independent sessions, commands, coordination and resources |
| `native/Sources/BrowserEngine/` | Engine contract and surface lifecycle |
| `native/Sources/BrowserEngineConformance/` | Shared engine acceptance checks |
| `native/Sources/Orbit/` | AppKit windows, sidebar, menus, palette, Peek and Split View |
| `native/Sources/WebKitEngine/` | Development and fallback backend used by SwiftPM |
| `native/OrbitChromium/` | CEF bridge, Chromium adapter, product composition, packaging and synthetic smoke driver |
| `native/OrbitChromium/cef-patches/` | Maintained CEF/Chromium patch sources and revision manifests |
| `native/Tests/` | Synthetic native tests |
| `native/ThirdParty/` | Public Suffix List data and its existing notices |

The engine contract keeps ownership tied to profile, window and tab identities. Chromium surfaces are hosted in AppKit views. Remote pages remain inside Chromium's sandbox; shell coordination is owned by the native application.

SwiftPM builds the shared Swift code and the WebKit development target. CMake builds the Chromium application with an external, matching CEF framework and wrapper. `native/ChromiumShell/` and `native/EngineGate/` are engine development probes, not the shipping browser.

Local state and imported browser profiles are runtime data, never build inputs. Tests use invented sessions and a mock Keychain. Normal product secure storage requires stable signing. Some sources/resources still use earlier internal names; the public project identity is Orbit. This module map does not claim complete feature or performance validation.
