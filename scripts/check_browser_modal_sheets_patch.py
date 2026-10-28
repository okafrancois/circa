#!/usr/bin/env python3
"""Check the browser-modal sheet patch (stacked on modal-dialog-host-r2) in private copies only.

Copies the R2-pinned Chromium inputs from --chromium-source into a temporary directory, verifies
them and the R2 Chromium patch against R2's manifest, applies R2, verifies that its outputs are
exactly this bundle's inputs, applies this bundle, verifies its outputs, then reverse-applies it.
The shared source tree is only read. Exit status is nonzero on any mismatch.
"""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
BUNDLE = REPO / 'native/OrbitChromium/cef-patches/browser-modal-sheets-r1/chromium'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git(stage, *args):
    return subprocess.run(['git', '-C', str(stage), *args], capture_output=True, text=True)


def check(chromium_source, r2_bundle, bundle=BUNDLE):
    manifest = json.loads((bundle / 'manifest.json').read_text())
    r2 = json.loads((r2_bundle / 'chromium/manifest.json').read_text())
    report = {'bundle_patch_sha256': sha(bundle / manifest['patch_file']), 'errors': []}
    errors = report['errors']
    if report['bundle_patch_sha256'] != manifest['patch_sha256']:
        errors.append('bundle patch hash differs from its manifest')
    r2_patch = r2_bundle / 'chromium' / r2['patch_file']
    if sha(r2_patch) != r2['patch_sha256'] or r2['patch_sha256'] != manifest['stacked_on']['chromium_patch_sha256']:
        errors.append('R2 Chromium patch is not the pinned base')
    if errors:
        return report
    with tempfile.TemporaryDirectory(prefix='orbit-modal-sheets-') as directory:
        stage = Path(directory)
        for relative, expected in r2['input_sha256'].items():
            source = Path(chromium_source) / relative
            if not source.is_file() or source.is_symlink() or sha(source) != expected:
                errors.append(f'R2 input mismatch: {relative}')
                continue
            (stage / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, stage / relative)
        if errors:
            return report
        subprocess.run(['git', 'init', '-q', str(stage)], check=True)
        for step, patch in (('r2', r2_patch), ('sheets', bundle / manifest['patch_file'])):
            result = git(stage, 'apply', '--check', '-p1', str(patch))
            if result.returncode:
                errors.append(f'{step} does not apply: {result.stderr.strip()[:300]}')
                return report
            git(stage, 'apply', '-p1', str(patch))
            if step == 'r2':
                for relative, expected in manifest['input_sha256'].items():
                    if sha(stage / relative) != expected or r2['output_sha256'].get(relative) != expected:
                        errors.append(f'R2 output is not this bundle input: {relative}')
        for relative, expected in manifest['output_sha256'].items():
            if sha(stage / relative) != expected:
                errors.append(f'output mismatch: {relative}')
        result = git(stage, 'apply', '-R', '--check', '-p1', str(bundle / manifest['patch_file']))
        if result.returncode:
            errors.append('bundle does not reverse cleanly')
        else:
            git(stage, 'apply', '-R', '-p1', str(bundle / manifest['patch_file']))
            for relative, expected in manifest['input_sha256'].items():
                if sha(stage / relative) != expected:
                    errors.append(f'reverse did not restore: {relative}')
        report['checked_outputs'] = sorted(manifest['output_sha256'])
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--chromium-source', required=True, type=Path)
    parser.add_argument('--r2-bundle', required=True, type=Path,
                        help='modal-dialog-host-r2 directory of commit 2f136c6785da')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = check(args.chromium_source.resolve(), args.r2_bundle.resolve())
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    sys.exit(1 if report['errors'] else 0)


if __name__ == '__main__':
    main()
