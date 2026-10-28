# Public Suffix List

- `public_suffix_list.dat`: verbatim copy of https://publicsuffix.org/list/public_suffix_list.dat,
  VERSION 2026-10-22_08-36-41_UTC, COMMIT 8437e5262f13305f94087abe699b4fe2be1d1de8,
  SHA-256 `0232f4df0831911356e8ee1f4d5c3b6b12c0ed3f6bd66b0f81c8ab5d3d49e9ca`, downloaded 2026-10-25.
  Mozilla Public License 2.0 (`LICENSE`, from https://www.mozilla.org/media/MPL/2.0/index.txt).
- `test_psl.txt`: official test vectors from https://github.com/publicsuffix/list (`tests/test_psl.txt`),
  public domain (CC0).

`native/Sources/BrowserCore/Sites/BrowserPublicSuffixData.swift` and
`native/Tests/BrowserCoreTests/BrowserPublicSuffixVectors.swift` are generated from these files:

```sh
python3 -I scripts/generate-public-suffix-swift.py \
  native/ThirdParty/publicsuffix/public_suffix_list.dat \
  native/Sources/BrowserCore/Sites/BrowserPublicSuffixData.swift \
  --tests native/ThirdParty/publicsuffix/test_psl.txt \
  native/Tests/BrowserCoreTests/BrowserPublicSuffixVectors.swift
```

To update: download the two files again, update this README (version, commit, hash, date), regenerate,
run `swift test --package-path native`.
