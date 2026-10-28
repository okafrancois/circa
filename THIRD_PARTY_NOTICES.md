# Third-party notices

Orbit's original code is licensed under the MIT License, Copyright (c) 2026 Okatech. That license does not replace the licenses or notices of its dependencies, copied upstream material, or engine patch context.

| Component | License and scope | Required treatment |
| --- | --- | --- |
| Chromium Embedded Framework (CEF) | BSD 3-Clause; external engine dependency and upstream context in patches | Retain CEF's copyright, conditions and disclaimer in source; reproduce them in binary distribution materials; do not imply endorsement. |
| Chromium | BSD 3-Clause for Chromium's own code; external engine dependency and upstream context in patches | Retain Chromium's copyright, conditions and disclaimer; retain each bundled third-party component's additional notices and license. |
| Sparkle | MIT for the updater framework's own code; planned dependency, not integrated in this snapshot | Include Sparkle's copyright and permission notice when shipped; preserve the additional licenses listed in its LICENSE file. |
| Public Suffix List data and generated `BrowserPublicSuffixData.swift` | Mozilla Public License 2.0 | Preserve `native/ThirdParty/publicsuffix/LICENSE`, source notices and attribution. Changes to covered files remain under MPL 2.0; Orbit's separate original files remain MIT. |

| Public Suffix List test vectors and generated `BrowserPublicSuffixVectors.swift` | CC0 / public domain, as stated by the upstream test vectors | Preserve the existing source/provenance headers; the separate MPL data-file license does not relicense these vectors. |

Complete upstream texts are retained in `docs/release/licenses/CEF-BSD.txt`, `Chromium-BSD.txt` and `Sparkle-LICENSE.txt`. The last includes Sparkle’s bundled external-license notices. These source notices must accompany the upstream context retained in the engine patches.

## License sources checked for this snapshot

- [CEF license](https://github.com/chromiumembedded/cef/blob/master/LICENSE.txt): copyright Marshall A. Greenblatt, with portions copyright Google Inc.; BSD redistribution conditions.
- [Chromium license](https://chromium.googlesource.com/chromium/src/+/main/LICENSE): copyright The Chromium Authors; BSD redistribution conditions.
- [Sparkle license and external licenses](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE): the framework's MIT notice, BSD notices for binary-diff/signature components, MIT sais-lite and the bundled Ed25519 license.
- Public Suffix List: its vendored README, data-file headers and MPL 2.0 license in `native/ThirdParty/publicsuffix/`.

The permissive BSD and MIT grants permit combining these components with Orbit's MIT code while retaining their own notices and conditions. They do not relicense upstream code as Okatech's work. The Public Suffix List has file-level MPL requirements rather than a requirement to license the entire application under MPL.

## Binary release requirements

Engine binaries are not present in this repository. Before shipping a binary, include the complete LICENSE/NOTICE material and generated third-party credits from the exact CEF/Chromium distribution being shipped, including its sandbox and helper dependencies. Do not assume all Chromium dependencies use BSD. Preserve the exact Sparkle release's complete license file when integrating the updater. This inventory is not a substitute for those bundled license texts.

CEF/Chromium builds with optional proprietary media codecs need a separate redistribution and patent review. The source license check does not grant patent rights for every codec. Public engine and installer distribution remain pending that review and the release validation described in `docs/release/distribution.md`.
