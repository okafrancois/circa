# Maintained-branch security roll (r28)

r28 carries the complete r27 composition unchanged onto Chromium **158.0.8127.90**.
CEF stays on the ported 8127 fork, wrapper API 15600 and side API v19. The r21
Chromium/CEF unions and every r22/r23/r24/r26/r27 delta remain required by the builder.
No stock engine replacement and no new fork patch are involved.

The upstream roll includes Variations signature validation/key rotation and HTTP fallback
hardening, older File System Access handle deserialization, and the corresponding dependency
rolls. See the [desktop security announcement](https://chromereleases.googleblog.com/2026/11/stable-channel-update-for-desktop_01734282054.html)
and [source delta](https://chromium.googlesource.com/chromium/src/+log/158.0.8127.65..158.0.8127.90).
Restricted vulnerability details prevent a claim of exploit reproduction. The existing
unbranded Variations fetch restriction remains in place.

On the r27 source tree, with no other writer:

```sh
python3 scripts/cef-engine-security-update.py --version 158.0.8127.90 --logs <new-backup-directory>
python3 scripts/cef-engine-r28-build.py --jobs 8
```

Inspect the backed-up source ledger and DEPS delta before building. The roll synchronizes
Git dependencies; this release has no CIPD or toolchain change. The builder holds the shared
source lock through source verification, compilation and distribution export, checks the
r27 exported hooks and version markers, and refuses to replace an existing r28 distribution.
Packaging and product qualification are separate steps; these source pins alone do not mean
that an engine has been shipped.
