#!/usr/bin/env python3
"""Capture archive settings and confirm restoration in a confined Chromium test bundle."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('archive_options_lab', REPO / 'scripts/orbit-chromium-lab.py')
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Synthetic Archive Page</title><p>Synthetic archive restoration.</p>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def phase(args):
    root, app = args.output.resolve(), args.app.resolve()
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
    (root / '.orbit-chromium-lab').write_text(lab.MARKER)
    lab.APP = app
    output = root / 'phase'
    output.mkdir(mode=0o700)
    (output / '.orbit-chromium-lab').write_text(lab.MARKER)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    command = [str(app / 'Contents/MacOS' / info['CFBundleExecutable']), '--use-mock-keychain',
               f'--orbit-data-root={data}', f'--orbit-smoke-run={output}',
               f'--orbit-smoke-fixture=http://127.0.0.1:{server.server_port}/',
               '--orbit-smoke-phase=fresh', '--orbit-smoke-archive-options',
               '-AppleLanguages', '(en)', '-AppleLocale', 'en_US']
    try:
        with lab.OwnedProcessRun() as owner:
            with (output / 'stdout.log').open('w') as out, (output / 'stderr.log').open('w') as err:
                process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)
                process.wait(timeout=50)
        results = json.loads((output / 'results.json').read_text())
        assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
        assert not results['aborted'] and all(row['status'] != 'failed' for row in results['results'])
        required = {'search', 'route', 'engine-document', 'never', 'cancel-keeps', 'confirm-clears'}
        proven = {row['id'] for row in results['results'] if row['status'] == 'proven'}
        assert {'archive-options.' + name for name in required} <= proven
        captures = {name + '-' + surface + '.png' for name in ('light', 'dark')
                    for surface in ('profile-settings', 'archive-menu', 'clear-confirmation')}
        assert captures <= {path.name for path in output.glob('*.png')}
        print(f'Archive options: {len(required)} checks, {len(captures)} captures, clean normal shutdown')
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    args = parser.parse_args()
    if args.phase:
        phase(args)
    else:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', 'python3', __file__,
                        '--app', str(args.app.resolve()), '--output', str(args.output.resolve()), '--phase'], check=True)


if __name__ == '__main__':
    main()
