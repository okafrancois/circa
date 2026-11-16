#!/usr/bin/env python3
"""Shell hardening checks in a confined test bundle: suggestions on erase-and-retype without and with
the cache (loopback fixture, fixed latency), settings writes during Space switches, session saves
under a burst and the Core Video motion link's display. Takes the GUI slot; sends no input events."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('perf_shell_b_lab', REPO / 'scripts/orbit-chromium-lab.py')
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)
SUGGESTION_LATENCY = 0.08


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path == '/suggest':
            query = parse_qs(url.query).get('q', [''])[0]
            time.sleep(SUGGESTION_LATENCY)
            body = json.dumps([query, [query + ' guide', query + ' news', query + ' tutorial']]).encode()
            kind = 'application/x-suggestions+json'
        else:
            body = b'<!doctype html><title>Synthetic Page</title><p>Synthetic page.</p>'
            kind = 'text/html'
        self.send_response(200)
        self.send_header('Content-Type', kind)
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
               '--orbit-smoke-phase=fresh', '--orbit-smoke-ai-settings', '--orbit-smoke-perf-shell-b',
               '-AppleLanguages', '(en)', '-AppleLocale', 'en_US']
    try:
        with lab.OwnedProcessRun() as owner:
            with (output / 'stdout.log').open('w') as out, (output / 'stderr.log').open('w') as err:
                process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)
                process.wait(timeout=55)
        results = json.loads((output / 'results.json').read_text())
        assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
        assert not results['aborted'] and all(row['status'] != 'failed' for row in results['results'])
        proven = {row['id'] for row in results['results'] if row['status'] == 'proven'}
        required = {'perf-shell-b.' + name for name in ('suggestions-before', 'suggestions-after', 'space-switch-writes',
                                                       'save-burst', 'core-video-link')}
        print(json.dumps({'missing': sorted(required - proven)}))
        print((output / 'perf-shell-b.json').read_text())
        assert required <= proven, sorted(required - proven)
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
