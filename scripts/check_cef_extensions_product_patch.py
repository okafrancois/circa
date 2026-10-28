#!/usr/bin/env python3
"""Validate the private extensions patch against pinned bytes; never mutate shared CEF."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
PATCH = REPO / 'native/OrbitChromium/cef-patches/extensions-product-r1'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(source):
    manifest = json.loads((PATCH / 'manifest.json').read_text())
    patch = PATCH / 'extensions-product-r1.patch'
    try:
        copy = json.loads((PATCH / 'chromium-inputs.json').read_text())
        if copy != manifest['chromium']:
            raise ValueError('mismatch')
    except (ValueError, OSError) as error:
        raise ValueError('Standalone Chromium fingerprint copy differs') from error
    if digest(patch) != manifest['patch_sha256']:
        raise ValueError('Private patch fingerprint mismatch')
    head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if head != manifest['cef_base']:
        raise ValueError('CEF commit differs from the reviewed input')
    for name, expected in manifest['input_sha256'].items():
        if digest(source / name) != expected:
            raise ValueError('CEF working bytes differ: ' + name)
    with tempfile.TemporaryDirectory(prefix='orbit-extensions-private-') as temp:
        private = Path(temp)
        for name in manifest['input_sha256']:
            target = private / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((source / name).read_bytes())
        for args in (['--check'], []):
            subprocess.run(['git', 'apply', *args, str(patch)], cwd=private, check=True)
        subprocess.run(['git', 'apply', '--reverse', '--check', str(patch)], cwd=private, check=True)
        for name, expected in manifest['output_sha256'].items():
            if digest(private / name) != expected:
                raise ValueError('Patched private output differs: ' + name)
        header = private / 'libcef/browser/orbit/orbit_cef_api.h'
        if header.read_bytes() != (REPO / 'native/OrbitChromium/Bridge/OrbitCefApi.h').read_bytes():
            raise ValueError('Side API and bridge header differ')
        for local, relative in [('orbit_extensions.inc', 'libcef/browser/orbit/orbit_extensions.inc'),
                                ('orbit_extension_popup.patch', 'patch/patches/orbit_extension_popup.patch')]:
            if (PATCH / local).read_bytes() != (private / relative).read_bytes():
                raise ValueError('Standalone review copy differs: ' + local)
        if (private / 'libcef/browser/orbit/orbit_extension_lease.h').read_bytes() != (REPO / 'native/OrbitChromium/Bridge/OrbitExtensionLease.h').read_bytes():
            raise ValueError('Native lease header and private CEF copy differ')
        chromium = source.parent
        for name, expected in manifest['chromium']['input_sha256'].items():
            if digest(chromium / name) != expected:
                raise ValueError('Chromium working bytes differ: ' + name)
            target = private / 'chromium' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((chromium / name).read_bytes())
        nested = private / 'patch/patches/orbit_extension_popup.patch'
        for args in (['--check'], []):
            subprocess.run(['git', 'apply', '-p0', *args, str(nested)], cwd=private / 'chromium', check=True)
        subprocess.run(['git', 'apply', '-p0', '--reverse', '--check', str(nested)],
                       cwd=private / 'chromium', check=True)
        for name, expected in manifest['chromium']['output_sha256'].items():
            if digest(private / 'chromium' / name) != expected:
                raise ValueError('Chromium private output differs: ' + name)
    # Detect ownership races rather than reporting a stale applicability result.
    for name, expected in manifest['input_sha256'].items():
        if digest(source / name) != expected:
            raise ValueError('Shared CEF changed during the private check')
    for name, expected in manifest['chromium']['input_sha256'].items():
        if digest(source.parent / name) != expected:
            raise ValueError('Shared Chromium changed during the private check')
    return {'applicable': True, 'sharedSourceWritten': False, 'compiled': False,
            'cefBase': head, 'patchSHA256': manifest['patch_sha256']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cef-source', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(check(args.cef_source), indent=2))
