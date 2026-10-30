#!/usr/bin/env python3
"""Check secure keyboard entry focus transitions in a synthetic Chromium bundle.

Every GUI session uses the shared slot for at most 55 seconds. Credentials, server and profile
are invented. No personal Keychain access.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import threading
import time
import plistlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('password_lab', REPO / 'scripts/orbit-chromium-lab.py')
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/auth':
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="Synthetic secure input"')
            self.end_headers()
            return
        body = b'<!doctype html><title>Secure input fixture</title><input id="plain" aria-label="Plain">'
        if self.path != '/plain':
            body += b'<input id="password" type="password" aria-label="Password">'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(body)


def phase(args):
    started = time.monotonic()
    root = args.output.resolve()
    directory = root / 'phase'
    directory.mkdir()
    (directory / '.orbit-chromium-lab').write_text(lab.MARKER)
    with (args.app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    assert info.get('OrbitSyntheticBundle') and info.get('OrbitUseMockKeychain')
    assert Path(info['OrbitDataRoot']).resolve() == root / 'data'
    lab.APP = args.app.resolve()
    command = [str(args.app / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
               f'--orbit-data-root={root}/data', f'--orbit-smoke-run={directory}',
               f'--orbit-smoke-fixture=http://127.0.0.1:{args.port}/',
               '--orbit-smoke-phase=fresh', '--orbit-smoke-secure-input']
    with lab.OwnedProcessRun() as owner:
        with (directory / 'stdout.log').open('w') as out, (directory / 'stderr.log').open('w') as err:
            process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                pass
    elapsed = time.monotonic() - started
    (directory / 'duration.json').write_text(json.dumps({'guiSeconds': elapsed}))
    assert elapsed < 60
    results = json.loads((directory / 'results.json').read_text())
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    (root / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
    assert not results['aborted'] and all(r['status'] != 'failed' for r in results['results'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    if args.phase:
        phase(args)
        return
    root = args.output.resolve()
    root.mkdir(mode=0o700, exist_ok=True)
    (root / '.orbit-chromium-lab').write_text(lab.MARKER)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', 'python3', __file__,
                        '--app', str(args.app.resolve()), '--output', str(root), '--phase',
                        '--port', str(server.server_port)], check=True)
    finally:
        server.shutdown(); server.server_close(); worker.join()
        with (args.app / 'Contents/Info.plist').open('rb') as stream:
            bundle_id = plistlib.load(stream)['CFBundleIdentifier']
        assert bundle_id.startswith('lab.orbit.orbit.')
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(args.app)], capture_output=True)
        subprocess.run(['defaults', 'delete', bundle_id], capture_output=True)
        subprocess.run(['tccutil', 'reset', 'All', bundle_id], capture_output=True)


if __name__ == '__main__':
    main()
