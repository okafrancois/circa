#!/usr/bin/env python3
"""Qualify history buttons and capture owned native menus on loopback documents."""
import argparse
import importlib.util
import json
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('history_bundle_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/favicon.svg':
            body = b'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" rx="6" fill="#327a52"/><circle cx="16" cy="16" r="8" fill="white"/></svg>'
            content_type = 'image/svg+xml'
        else:
            body = ('<!doctype html><title>History ' + self.path.strip('/').title()
                    + '</title><link rel="icon" href="/favicon.svg"><h1>Synthetic history</h1>').encode()
            content_type = 'text/html'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    lab.APP = args.app.resolve()
    data = root / 'data'
    state = data / 'perf-state.json'
    control = data / 'perf-command.json'
    nonce = str(time.monotonic_ns())
    def timeout(*_):
        raise TimeoutError('50-second GUI lease')
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(50)
    started = time.monotonic()
    with lab.OwnedProcessRun() as owner:
        with (root / 'runtime-stdout.log').open('w') as out, (root / 'runtime-stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
                                    '--perf-probe', f'--orbit-data-root={data}'],
                                   stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 12
                def ready():
                    try:
                        return json.loads(state.read_text()).get('pid') == process.pid
                    except (OSError, ValueError):
                        return False
                while not ready():
                    assert process.poll() is None, 'Synthetic app exited before readiness'
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                pending = data / 'perf-command.pending'
                pending.write_text(json.dumps({'command': 'navigation-history', 'nonce': nonce,
                                               'url': f'http://127.0.0.1:{args.port}/',
                                               'capture': 'onscreen' if args.onscreen else 'offscreen'}))
                pending.replace(control)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'navigationHistory' in result:
                        checks = result['navigationHistory']
                        break
                    assert process.poll() is None, 'Synthetic app exited during qualification'
                    time.sleep(.05)
                else:
                    raise TimeoutError('Navigation history probe')
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=5)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    checks['guiSeconds'] = time.monotonic() - started
    (root / 'verification.json').write_text(json.dumps(checks, indent=2) + '\n')
    for key in ('selectedFirst', 'selectedThird', 'commandOpenedBackground', 'adjacent'):
        assert checks.get(key), checks
    assert checks['backLight'] == checks['backDark'] == ['History Second', 'History First'], checks
    assert checks['forwardLight'] == checks['forwardDark'] == ['History Second', 'History Third'], checks
    if args.onscreen:
        for name in ('back-light', 'back-dark', 'forward-light', 'forward-dark'):
            assert (data / (name + '.png')).is_file(), name
    print('Real engine history passed; owned GUI lease %.2f s' % checks['guiSeconds'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Bundle must use lab.orbit.orbit.nav-history-menu and a baked <output>/data root')
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--onscreen', action='store_true', help='Briefly place the owned synthetic window onscreen for native menu captures')
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    if args.phase:
        phase(args)
        return
    args.output.mkdir(parents=True, exist_ok=True)
    validation.validate_bundle(args.app.resolve(), args.output.resolve())
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
                        '--app', str(args.app.resolve()), '--output', str(args.output.resolve()),
                        '--phase', '--port', str(server.server_port), *(['--onscreen'] if args.onscreen else [])], check=True, timeout=60)
    finally:
        server.shutdown()


if __name__ == '__main__':
    main()
