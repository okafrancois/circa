#!/usr/bin/env python3
"""Qualify the shell load allowlist on the real engine: built-in pages, PDF and restore still load,
debug pages and javascript: from shell paths do nothing. Two owned GUI leases (run, relaunch)."""
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
SPEC = importlib.util.spec_from_file_location('guard_bundle_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab


def synthetic_pdf():
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>']
    body, offsets = b'%PDF-1.4\n', []
    for index, value in enumerate(objects, 1):
        offsets.append(len(body))
        body += b'%d 0 obj\n%s\nendobj\n' % (index, value)
    xref = len(body)
    body += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objects) + 1)
    body += b''.join(b'%010d 00000 n \n' % offset for offset in offsets)
    return body + b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objects) + 1, xref)


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/doc.pdf':
            body, content_type = synthetic_pdf(), 'application/pdf'
        else:
            body, content_type = b'<!doctype html><title>Guard Page</title><h1>Synthetic guard</h1>', 'text/html'
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
        with (root / f'{args.phase}-stdout.log').open('w') as out, (root / f'{args.phase}-stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
                                    '--perf-probe', f'--orbit-data-root={data}'],
                                   stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 15
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
                pending.write_text(json.dumps({'command': 'nav-scheme-guard', 'nonce': nonce, 'action': args.phase,
                                               'url': f'http://127.0.0.1:{args.port}/'}))
                pending.replace(control)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'navigationGuard' in result:
                        checks = result['navigationGuard']
                        break
                    assert process.poll() is None, 'Synthetic app exited during qualification'
                    time.sleep(.05)
                else:
                    raise TimeoutError('Navigation guard probe')
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=8)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    checks['guiSeconds'] = time.monotonic() - started
    (root / f'{args.phase}.json').write_text(json.dumps(checks, indent=2) + '\n')
    print(args.phase, json.dumps(checks, sort_keys=True))
    if args.phase == 'run':
        for key in ('web', 'crashIgnored', 'sessionKillIgnored', 'webStillAlive', 'settings', 'extensions', 'pdf'):
            assert checks.get(key) is True, (key, checks)
    else:
        # The extension manager page loads only when opened through Manage Extensions (the bridge
        # arms its route); a restored chrome://extensions tab stays blank independently of this guard.
        loaded = {key: value for key, value in checks.get('loaded', {}).items() if key != 'chrome:extensions/'}
        assert loaded and all(loaded.values()), checks
        assert checks.get('webTitle') == 'Guard Page', checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Bundle must use lab.orbit.orbit.nav-scheme-guard and a baked <output>/data root')
    parser.add_argument('--phase', choices=('run', 'restore'))
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
        for name in ('run', 'restore'):
            subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
                            '--app', str(args.app.resolve()), '--output', str(args.output.resolve()),
                            '--phase', name, '--port', str(server.server_port)], check=True, timeout=60)
    finally:
        server.shutdown()


if __name__ == '__main__':
    main()
