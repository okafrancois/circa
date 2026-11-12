#!/usr/bin/env python3
"""Check the candidate popup exclusion patch privately; never mutate shared CEF."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

PATCH = Path(__file__).resolve().parent.parent / 'native/OrbitChromium/cef-patches/extension-popup-latency'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(source, *, applied=False):
    manifest = json.loads((PATCH / 'manifest.json').read_text())
    patch = PATCH / 'cef.patch'
    if digest(patch) != manifest['patch_sha256']:
        raise ValueError('Patch fingerprint differs')
    shared_hashes = manifest['output_sha256' if applied else 'input_sha256']
    with tempfile.TemporaryDirectory(prefix='orbit-popup-latency-') as temporary:
        private = Path(temporary)
        for name, expected in shared_hashes.items():
            if digest(source / name) != expected:
                raise ValueError('Source bytes differ: ' + name)
            target = private / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((source / name).read_bytes())
        if applied:
            subprocess.run(['git', 'apply', '--reverse', str(patch)], cwd=private, check=True)
        for name, expected in manifest['input_sha256'].items():
            if digest(private / name) != expected:
                raise ValueError('Reconstructed input differs: ' + name)
        for options in (['--check'], []):
            subprocess.run(['git', 'apply', *options, str(patch)], cwd=private, check=True)
        subprocess.run(['git', 'apply', '--reverse', '--check', str(patch)], cwd=private, check=True)
        for name, expected in manifest['output_sha256'].items():
            if digest(private / name) != expected:
                raise ValueError('Output bytes differ: ' + name)
    for name, expected in shared_hashes.items():
        if digest(source / name) != expected:
            raise ValueError('Shared source changed during validation')
    return {'applicable': True, 'sharedSourceWritten': False,
            'sourceState': 'applied' if applied else 'unapplied'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cef-source', required=True, type=Path)
    parser.add_argument('--applied', action='store_true', help='Validate an already patched source privately')
    args = parser.parse_args()
    print(json.dumps(check(args.cef_source, applied=args.applied), indent=2))
