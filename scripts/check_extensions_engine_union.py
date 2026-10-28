#!/usr/bin/env python3
"""Check, in private copies only, the complete extensions-outcome engine union (R2).

One union on the approved EssentialsR2 CEF base 0e5315e and Chromium 156.0.8078.48, in order:

  CEF       1. modal-dialog-host-r2           window-owned modal host + AppKit registration
            2. extensions-product-r1 (v4)     extension service, popup carrier (patch.cfg) and the
                                              reviewed existing-directory repair (ca0d53d / 19ed6a2c)
            3. unowned-tabs-r2                Chrome-created tabs offered to the embedder (B1/B2)
            4. installer-downloads-r1         native Web Store installer transfer ownership (A1)
  Chromium  5. modal-dialog-host-r2           AppKit modal parent adapter
            6. browser-modal-sheets-r1        kWindow sheets, parented bubbles
            7. orbit_extension_popup           native-parent action popup (carried by step 2)
            8. unowned-tabs-r2                Navigate() creation intent

Base CEF bytes come from `git show 0e5315e:<path>`; Chromium bytes are copied from the shared
tree, whose pinned working inputs include CEF's own Chromium patches. When the shared tree retains
the R4 popup working state, the popup inputs are reconstructed privately by reverse application
and then verified. Every pinned input and output is checked, every step is reversed back to the
exact originals, and new files must disappear. The shared tree is only read.
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
PATCHES = REPO / 'native/OrbitChromium/cef-patches'
CEF_BASE = '0e5315e2fd06795cafe7e83bf6bf94a3ab405e8f'
R2_COMMIT = '2f136c6785da724e2ddc93c5e048627de38f13f5'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(stage, *args):
    return subprocess.run(['git', '-C', str(stage), *args], capture_output=True, text=True)


def commit(stage, message):
    git(stage, 'add', '-A')
    git(stage, '-c', 'user.email=check@invalid', '-c', 'user.name=check', 'commit', '-qm', message)


def bundles(r2_bundle):
    """(name, role, patch path or None for the carried popup, manifest, strip) in order."""
    def load(path):
        return json.loads(path.read_text())
    r2_cef = load(r2_bundle / 'cef/manifest.json')
    r2_chromium = load(r2_bundle / 'chromium/manifest.json')
    v4 = load(PATCHES / 'extensions-product-r1/manifest.json')
    popup = {'input_sha256': v4['chromium']['input_sha256'], 'output_sha256': v4['chromium']['output_sha256']}
    return [
        ('modal-host-r2 CEF', 'cef', r2_bundle / 'cef' / r2_cef['patch_file'], r2_cef, 1),
        ('extensions v4 + existing directory', 'cef', PATCHES / 'extensions-product-r1/extensions-product-r1.patch', v4, 1),
        ('unowned-tabs-r2 CEF', 'cef', PATCHES / 'unowned-tabs-r2/cef/cef.patch',
         load(PATCHES / 'unowned-tabs-r2/cef/manifest.json'), 1),
        ('installer-downloads-r1', 'cef', PATCHES / 'installer-downloads-r1/cef/cef.patch',
         load(PATCHES / 'installer-downloads-r1/cef/manifest.json'), 1),
        ('modal-host-r2 Chromium', 'chromium', r2_bundle / 'chromium' / r2_chromium['patch_file'], r2_chromium, 1),
        ('browser-modal-sheets-r1', 'chromium', PATCHES / 'browser-modal-sheets-r1/chromium/chromium.patch',
         load(PATCHES / 'browser-modal-sheets-r1/chromium/manifest.json'), 1),
        ('extension popup (carried by v4)', 'chromium', None, popup, 0),
        ('unowned-tabs-r2 Chromium', 'chromium', PATCHES / 'unowned-tabs-r2/chromium/chromium.patch',
         load(PATCHES / 'unowned-tabs-r2/chromium/manifest.json'), 1),
    ]


def original_inputs(steps):
    """Per role, inputs whose bytes come from outside the union (first consumer wins)."""
    originals = {'cef': {}, 'chromium': {}}
    produced = {'cef': set(), 'chromium': set()}
    for _, role, _, manifest, _ in steps:
        for relative, expected in manifest['input_sha256'].items():
            if relative not in produced[role]:
                originals[role].setdefault(relative, expected)
        produced[role] |= set(manifest['output_sha256'])
    return originals


def check(cef_git, chromium_source, r2_bundle, stage_out=None):
    errors = []
    steps = bundles(r2_bundle)
    report = {'steps': [], 'errors': errors}
    if json.loads((r2_bundle / 'cef/manifest.json').read_text())['source_reference'] != CEF_BASE:
        errors.append('R2 CEF base is not the approved EssentialsR2 base')
    for name, role, patch, manifest, _ in steps:
        if patch is None:
            continue
        digest = sha(patch.read_bytes())
        if manifest.get('patch_sha256') != digest:
            errors.append(f'unpinned patch: {name}')
        report['steps'].append({'step': name, 'role': role, 'patch_sha256': digest})
    if errors:
        return report
    with tempfile.TemporaryDirectory(prefix='orbit-ext-union-r2-') as directory:
        stages = {'cef': Path(directory) / 'cef', 'chromium': Path(directory) / 'chromium'}
        for stage in stages.values():
            stage.mkdir()
            subprocess.run(['git', 'init', '-q', str(stage)], check=True)
        originals = original_inputs(steps)
        for relative in sorted(originals['cef']):
            data = subprocess.run(['git', '-C', str(cef_git), 'show', f'{CEF_BASE}:{relative}'],
                                  capture_output=True, check=True).stdout
            (stages['cef'] / relative).parent.mkdir(parents=True, exist_ok=True)
            (stages['cef'] / relative).write_bytes(data)
        for relative in sorted(originals['chromium']):
            source = chromium_source / relative
            if not source.is_file() or source.is_symlink():
                errors.append(f'missing Chromium input: {relative}')
                continue
            (stages['chromium'] / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, stages['chromium'] / relative)
        if errors:
            return report
        popup = steps[6][3]
        retained_r4 = all(sha((stages['chromium'] / f).read_bytes()) == h for f, h in popup['output_sha256'].items())
        report['popup_inputs'] = 'reconstructed-from-retained-R4-state' if retained_r4 else 'shared'
        if retained_r4:
            # The carrier is a v4 output: reconstruct it privately from the pinned base first.
            with tempfile.TemporaryDirectory() as carrier:
                carrier = Path(carrier)
                subprocess.run(['git', 'init', '-q', str(carrier)], check=True)
                for relative in steps[1][3]['input_sha256']:
                    (carrier / relative).parent.mkdir(parents=True, exist_ok=True)
                    (carrier / relative).write_bytes((stages['cef'] / relative).read_bytes())
                if git(carrier, 'apply', '-p1', str(steps[1][2])).returncode:
                    errors.append('popup carrier reconstruction failed')
                    return report
                carried = carrier / 'patch/patches/orbit_extension_popup.patch'
                if git(stages['chromium'], 'apply', '-p0', '-R', str(carried)).returncode:
                    errors.append('popup reverse to its pinned inputs failed')
                    return report
                git(stages['chromium'], 'apply', '-p0', '-R', str(carried))
        for role in stages:
            for relative, expected in originals[role].items():
                if sha((stages[role] / relative).read_bytes()) != expected:
                    errors.append(f'{role} original input mismatch: {relative}')
        if errors:
            return report
        for stage in stages.values():
            commit(stage, 'pinned originals')
        applied = []
        for name, role, patch, manifest, strip in steps:
            stage = stages[role]
            if patch is None:
                patch_bytes = (stages['cef'] / 'patch/patches/orbit_extension_popup.patch').read_bytes()
                patch = Path(directory) / 'orbit_extension_popup.patch'
                patch.write_bytes(patch_bytes)  # Kept for the final reverse after CEF reverses.
            for relative, expected in manifest['input_sha256'].items():
                if not (stage / relative).is_file() or sha((stage / relative).read_bytes()) != expected:
                    errors.append(f'{name}: input mismatch {relative}')
            if errors:
                break
            git(stage, 'add', '-A')
            git(stage, '-c', 'user.email=check@invalid', '-c', 'user.name=check', 'commit', '-q',
                '--allow-empty', '-m', f'before {name}')
            checked = git(stage, 'apply', f'-p{strip}', '--check', str(patch))
            if checked.returncode:
                errors.append(f'{name}: does not apply: {checked.stderr.strip()[:300]}')
                break
            git(stage, 'apply', f'-p{strip}', str(patch))
            for relative, expected in manifest['output_sha256'].items():
                if sha((stage / relative).read_bytes()) != expected:
                    errors.append(f'{name}: output mismatch {relative}')
            applied.append((name, stage, patch, strip))
        if errors:
            return report
        final = {role: {str(p.relative_to(stage)): sha(p.read_bytes())
                        for p in sorted(stage.rglob('*')) if p.is_file() and '.git' not in p.parts}
                 for role, stage in stages.items()}
        report['final_files'] = {role: len(files) for role, files in final.items()}
        report['final_digest'] = sha(json.dumps(final, sort_keys=True).encode())
        report['final_sha256'] = final
        pinned = json.loads((PATCHES / 'extensions-union-r2/union.json').read_text())['final']
        if pinned['digest_sha256'] != report['final_digest'] or pinned['per_file_sha256'] != final:
            errors.append('final union differs from extensions-union-r2/union.json')
        if stage_out:
            if stage_out.exists() and any(stage_out.iterdir()):
                errors.append('stage output directory is not empty')
                return report
            for role, stage in stages.items():
                shutil.copytree(stage, stage_out / role, ignore=shutil.ignore_patterns('.git'))
        # Reverse every step, newest first; each must restore the state committed before it.
        for name, stage, patch, strip in reversed(applied):
            result = git(stage, 'apply', f'-p{strip}', '-R', str(patch))
            if result.returncode:
                errors.append(f'{name}: does not reverse: {result.stderr.strip()[:200]}')
                break
            git(stage, 'add', '-A')
            leftover = git(stage, 'diff', '--cached', '--name-only', f'HEAD').stdout.strip()
            if leftover:
                errors.append(f'{name}: reverse differs from its prestate: {leftover[:200]}')
                break
            git(stage, 'reset', '-q', '--soft', 'HEAD~1')
        if not errors:
            for role, stage in stages.items():
                if git(stage, 'rev-list', '--count', 'HEAD').stdout.strip() != '1':
                    errors.append(f'{role}: reverse did not reach the original shared bytes')
        report['reversed'] = not errors
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cef-git', required=True, type=Path)
    parser.add_argument('--chromium-source', required=True, type=Path)
    parser.add_argument('--r2-bundle', required=True, type=Path,
                        help=f'modal-dialog-host-r2 directory of commit {R2_COMMIT[:12]}')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--stage-out', type=Path, help='private empty directory receiving the union outputs')
    args = parser.parse_args()
    report = check(args.cef_git.resolve(), args.chromium_source.resolve(), args.r2_bundle.resolve(),
                   args.stage_out.resolve() if args.stage_out else None)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'final_sha256'}, indent=2))
    sys.exit(1 if report['errors'] else 0)


if __name__ == '__main__':
    main()
