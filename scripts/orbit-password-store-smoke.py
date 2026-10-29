#!/usr/bin/env python3
"""Qualify the asynchronous password store in a confined mock-Keychain bundle."""
import argparse
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('password_store_lab', REPO / 'scripts/orbit-chromium-lab.py')
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(b'<!doctype html><title>Synthetic password store</title>')


def validate_bundle(app, root):
    root = root.resolve()
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    identifier = info.get('CFBundleIdentifier', '')
    expected = root / 'data'
    if not (info.get('OrbitSyntheticBundle') is True and info.get('OrbitUseMockKeychain') is True
            and identifier.startswith('lab.orbit.orbit.') and info.get('OrbitDataRoot') == str(expected)):
        raise ValueError('A confined synthetic mock-Keychain bundle is required')
    marker = expected / '.orbit-synthetic-root'
    if expected.is_symlink() or marker.is_symlink() or json.loads(marker.read_text()) != {
            'bundleID': identifier, 'owner': os.getuid(), 'version': 1}:
        raise ValueError('Synthetic data root ownership mismatch')


def phase(args):
    root = args.output.resolve()
    validate_bundle(args.app, root)
    lab.APP = args.app.resolve()
    directory = root / 'phase'
    directory.mkdir(mode=0o700)
    (directory / '.orbit-chromium-lab').write_text(lab.MARKER)
    command = [str(args.app / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
               f'--orbit-data-root={root}/data', f'--orbit-smoke-run={directory}',
               f'--orbit-smoke-fixture=http://127.0.0.1:{args.port}/',
               '--orbit-smoke-phase=fresh', '--orbit-smoke-password-store']
    with lab.OwnedProcessRun() as owner:
        with (directory / 'stdout.log').open('w') as out, (directory / 'stderr.log').open('w') as err:
            process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                process.wait(timeout=53)
            except subprocess.TimeoutExpired:
                pass
    results = json.loads((directory / 'results.json').read_text())
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    assert not results['aborted'] and all(r['status'] != 'failed' for r in results['results'])
    ids = {r['id'] for r in results['results'] if r['status'] == 'proven'}
    required = {'empty', 'add-observed', 'round-trip', 'profile-isolation', 'duplicate-conflict',
                'update', 'update-observed', 'key-update', 'key-update-observed', 'blocklist-observed',
                'remove-observed', 'blocklist-preserved', 'missing-conflict', 'private-refused',
                'second-handle', 'pending-cancelled', 'final-empty', 'stream-closed',
                'teardown-observer', 'profile-teardown-revoked'}
    assert {'password-store.' + name for name in required} <= ids
    (root / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'Password store smoke: {len(required)} checks passed; clean normal shutdown')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Bundle must be baked with --synthetic-root <output>/data')
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    if args.phase:
        phase(args)
        return
    root = args.output.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    assert not (root / 'phase').exists(), 'Use a fresh output directory'
    (root / '.orbit-chromium-lab').write_text(lab.MARKER)
    validate_bundle(args.app, root)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', 'python3', __file__,
                        '--app', str(args.app.resolve()), '--output', str(root), '--phase',
                        '--port', str(server.server_port)], check=True, timeout=60)
    finally:
        server.shutdown(); server.server_close(); worker.join()


if __name__ == '__main__':
    main()
