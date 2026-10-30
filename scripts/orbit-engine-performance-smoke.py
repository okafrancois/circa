#!/usr/bin/env python3
"""Qualify lifecycle, bounded capture and activation callbacks in a confined bundle."""
import argparse
import importlib.util
import json
import plistlib
import signal
from pathlib import Path
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('performance_bundle_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        body = b'<!doctype html><title>Synthetic page state</title><input id="input"><div contenteditable id="edit">Synthetic</div>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
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
    def expired(*_):
        raise TimeoutError('Bounded GUI lease')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(35)
    with lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
                                    '--perf-probe', f'--orbit-data-root={data}'],
                                   stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 12
                while not state.exists():
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                command = {'command': 'native-performance', 'step': 'core', 'nonce': nonce,
                           'url': f'http://127.0.0.1:{args.port}/'}
                temporary = data / 'perf-command.pending'
                temporary.write_text(json.dumps(command))
                temporary.replace(control)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'nativePerformance' in result:
                        checks = result['nativePerformance']
                        break
                    time.sleep(.05)
                else:
                    raise TimeoutError('Native performance probe')
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=3)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    required = {'lifecycle', 'trustedEdits', 'formInteraction', 'webLock', 'editsResetOnNavigation',
                'captureSizeAndMemory', 'stripSizeAndMemory', 'hiddenCapture', 'discardAccepted',
                'embedderDiscard', 'activationVisible', 'submitted', 'documentChanged', 'hidden', 'timedOut', 'superseded', 'closed'}
    if plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'].endswith(('engine-r12', 'engine-r13')):
        required |= {'memoryDump', 'memoryAllocators'}
    assert all(checks.get(name) is True for name in required), checks
    (root / 'verification.json').write_text(json.dumps(checks, indent=2) + '\n')
    print(f'Native performance smoke: {len(required)} checks passed; clean normal shutdown')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Bundle must use lab.orbit.orbit.engine-r11 and <output>/data')
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    with (args.app / 'Contents/Info.plist').open('rb') as stream:
        assert plistlib.load(stream)['CFBundleIdentifier'] in ('lab.orbit.orbit.engine-r11', 'lab.orbit.orbit.engine-r12', 'lab.orbit.orbit.engine-r13')
    if args.phase:
        phase(args)
        return
    assert not (root / 'data/perf-state.json').exists(), 'Use a fresh synthetic root'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
                        '--app', str(args.app.resolve()), '--output', str(root), '--phase',
                        '--port', str(server.server_port)], check=True)
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


if __name__ == '__main__':
    main()
