# Orbit application identity

`Orbit.svg` follows the App icon section in `docs/brand/orbit/orbit-da.html`:
an open Halo/Dawn/Sun ring and warm white satellite on orbital ink.
The tile has 23% corner radii, 72% mark scale and a transparent outer margin.

Regenerate `Orbit.icns` and the review PNG with `python3 scripts/orbit-app-icon.py`.
The macOS CoreSVG renderer draws the vector directly at each resolution.
The ICNS contains 16, 32, 128, 256 and 512 point representations at both scales
(including 64px and 1024px Retina images). The generator checks decoded pixels.

Production identity is defined in `native/Sources/BrowserCore/ProductIdentity.swift`.
CMake and Python packaging read those literals. The executable and Swift modules
retain their internal Orbit names. The stable development signing certificate is
preserved; production builds use the new bundle identifier.

`Orbit.icns` and its provenance remain historical Orbit assets, unused by Orbit packaging.
