#!/usr/bin/env python3
"""Exercise page translation in a confined, mock-Keychain Chromium test bundle."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('translation_lab', REPO / 'scripts/orbit-chromium-lab.py')
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


def validate_bundle(app, root):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    identifier = info.get('CFBundleIdentifier', '')
    data = root / 'data'
    if not (info.get('OrbitSyntheticBundle') is True and info.get('OrbitUseMockKeychain') is True
            and identifier.startswith('lab.orbit.orbit.') and info.get('OrbitDataRoot') == str(data)):
        raise ValueError('A confined synthetic mock-Keychain bundle is required')
    marker = data / '.orbit-synthetic-root'
    if data.is_symlink() or marker.is_symlink() or json.loads(marker.read_text()) != {
            'bundleID': identifier, 'owner': os.getuid(), 'version': 1}:
        raise ValueError('Synthetic data root ownership mismatch')


def phase(args):
    root = args.output.resolve()
    app = args.app.resolve()
    validate_bundle(app, root)
    lab.APP = app
    phase = root / "phase"
    phase.mkdir(mode=0o700)
    (phase / ".orbit-chromium-lab").write_text(lab.MARKER)
    command = [str(app / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
               f'--orbit-data-root={root}/data', f'--orbit-smoke-run={phase}',
               '--orbit-smoke-fixture=http://127.0.0.1:9/', '--orbit-smoke-phase=fresh',
               '--orbit-smoke-translation', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US']
    if args.probe_only:
        command.append('--translation-probe-only')
    with lab.OwnedProcessRun() as owner:
        with (phase / 'stdout.log').open('w') as out, (phase / 'stderr.log').open('w') as err:
            process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            process.wait(timeout=55)
    results = json.loads((phase / 'results.json').read_text())
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    assert not results['aborted'] and all(row['status'] != 'failed' for row in results['results'])
    proven = {row['id'] for row in results['results'] if row['status'] == 'proven'}
    required = {'page-loaded', 'chromium-no-key-refused'}
    if not args.probe_only:
        required |= {'available', 'offer-click', 'original-click', 'translated', 'english-heading', 'same-document', 'restored', 'german-heading', 'dynamic-content', 'interactive', 'dynamic-restored'}
    assert {'translation.' + name for name in required} <= proven
    print(f'Translation smoke: {len(required)} checks passed; clean normal shutdown')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Bundle must be baked with --synthetic-root <output>/data')
    parser.add_argument('--probe-only', action='store_true')
    parser.add_argument('--phase', action='store_true')
    args = parser.parse_args()
    root = args.output.resolve()
    validate_bundle(args.app.resolve(), root)
    if args.phase:
        phase(args)
        return
    assert not (root / 'phase').exists(), 'Use a fresh output directory'
    (root / '.orbit-chromium-lab').write_text(lab.MARKER)
    command = ['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', 'python3', __file__,
               '--app', str(args.app.resolve()), '--output', str(root), '--phase']
    if args.probe_only:
        command.append('--probe-only')
    subprocess.run(command, check=True)


if __name__ == '__main__':
    main()
