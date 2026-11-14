# Owned-directory OSCrypt compatibility (r22)

r22 is the complete r21 union (CEF 8127, Chromium **158.0.8127.37**, side API v18,
`engine-r21/cef.patch` and `engine-r21/chromium.patch` unchanged) plus one Chromium change,
`os-crypt-owned-directory.patch`.

Chromium 158 enables `KeychainKeyProviderUserDataDirProtection` on macOS. For a user data
directory other than Chrome's default, `BrowserProcessImpl` registers an unavailable `v10`
key and a new `v11` key (same Keychain password, salt `pepper`). Every embedder directory is
non-default, so cookies written by Chromium 156 (`v10`, salt `saltysalt`) no longer
decrypt, and `SQLitePersistentCookieStore` deletes the whole eTLD+1 group of a cookie it
cannot decrypt. Sites were signed out after the update and their rows were removed.

The patch registers the real `v10` Keychain provider, below `v11` in precedence, only when
`--orbit-owned-user-data-dir` equals `chrome::DIR_USER_DATA`. The bridge appends that switch
with the anchored `root_cache_path`; it never comes from process or shell arguments
(`FilterBrowserArguments` drops it). Result in the owned directory: `v10` and `v11` data both
decrypt and new data is written as `v11`. Any other directory keeps the upstream protection.
Keychain items, ACLs and keys are unchanged.

Rebuild on the r21 tree:

```sh
python3 scripts/cef-engine-r22-build.py --apply --jobs 8
```

The builder checks the r21 pins, the applied r21 union and the delta checksum, applies the
delta under the shared source lock, and refuses to replace r22.
