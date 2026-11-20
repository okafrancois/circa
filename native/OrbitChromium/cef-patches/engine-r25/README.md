# Security release 158.0.8127.65 (r25)

r25 is the complete r24 composition, unchanged, on Chromium **158.0.8127.65**, a later
security release of the same branch (CEF 8127, side API v19):

- `engine-r21/cef.patch` and `engine-r21/chromium.patch` (fork unions);
- `engine-r22/os-crypt-owned-directory.patch` and `engine-r23/system-passkeys.patch`;
- `engine-r24/chromium-delta.patch` and `engine-r24/cef-delta.patch`.

No new patch, mojom, build file or public CEF API change. Compared with 158.0.8127.37, the
release adds the branch's later merges in Chromium and rolls V8, Skia, ANGLE, Dawn, PDFium,
ICU and LevelDB (revisions in `source.json`). No toolchain, CIPD or hook change.

Rebuild on the r24 tree:

```sh
python3 scripts/cef-engine-security-update.py --version 158.0.8127.65 --logs <fresh dir>
python3 scripts/cef-engine-r25-build.py --jobs 8
```

The update backs up every working change of the source tree and of each changed dependency,
checks out the release and 3-way merges the changes back; it stops on a conflict. The
builder checks the release commit, dependency revisions, conflict markers, the r21 unions and
that the r22, r23 and both r24 deltas are applied, requires the CEF checkout to be the fork
union with the r24 CEF delta as its only uncommitted change, checks that the exported
framework carries the v19 sources, the passkey group and the release version, and refuses
to replace r25.
