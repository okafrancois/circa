#!/usr/bin/env python3
"""Exercise side API v17 in an isolated, hosted-product synthetic bundle."""
import argparse
import importlib.util
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('engine_bundle_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        body = b'<!doctype html><title>Engine r17 fixture</title><p>Synthetic page</p>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class SocketListener:
    def __init__(self):
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('127.0.0.1', 0))
        self.sock.listen(16)
        self.sock.settimeout(.2)
        self.port = self.sock.getsockname()[1]
        self.count = 0
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while True:
            try:
                client, _ = self.sock.accept()
            except (OSError, TimeoutError):
                if self.sock.fileno() < 0:
                    return
                continue
            with self.lock:
                self.count += 1
            client.close()

    def close(self):
        self.sock.close()
        self.thread.join(timeout=1)


def phase(args):
    root = args.output.resolve()
    app = args.app.resolve()
    validation.validate_bundle(app, root)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        import plistlib
        assert plistlib.load(stream)['CFBundleIdentifier'] == 'lab.orbit.orbit.engine-r17'
    lab.APP = app
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    nonce = str(time.monotonic_ns())
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('43-second GUI lease')))
    signal.alarm(43)
    started = time.monotonic()
    with lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(app / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--perf-probe',
                f'--orbit-data-root={data}'], stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 12
                while not state.exists():
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                ports = ','.join(str(listener.port) for listener in args.listeners)
                command = {'command': 'native-r17', 'nonce': nonce,
                           'url': f'http://127.0.0.1:{args.http_port}/', 'ports': ports}
                pending = data / 'perf-command.pending'
                pending.write_text(json.dumps(command))
                pending.replace(control)
                receipt_deadline = time.monotonic() + 5
                receipt = None
                while time.monotonic() < receipt_deadline:
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    candidate = result.get('commandReceipt')
                    if isinstance(candidate, dict) and candidate.get('nonce') == nonce:
                        receipt = candidate
                        break
                    time.sleep(.05)
                if receipt is None:
                    raise TimeoutError('Native r17 command receipt; state=' + json.dumps(result, sort_keys=True))

                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'nativeR17' in result:
                        checks = result['nativeR17']
                        break
                    time.sleep(.05)
                else:
                    progress = result.get('nativeR17Progress', {})
                    raise TimeoutError('Native r17 probe; progress=' + json.dumps(progress, sort_keys=True))
                checks['commandReceipt'] = receipt
                checks['progressTrace'] = result.get('nativeR17Progress', {})
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=3)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    for _ in range(30):
        if all(listener.count > 0 for listener in args.listeners[:6]):
            break
        time.sleep(.05)
    checks['preconnectAcceptedSocketsByPort'] = [listener.count for listener in args.listeners]
    checks['guiSecondsIncludingCleanup'] = time.monotonic() - started
    checks['preconnectPrivateProfile'] = 'not exercised: this probe has no private-profile creation seam'
    checks['preconnectPreferenceOff'] = 'not exercised: no synthetic preference mutation seam'
    (root / 'verification.json').write_text(json.dumps(checks, indent=2) + '\n')

    required_true = ('visibleVetoBit', 'webLockVetoBit', 'audibleVetoBit', 'freezeAddRemoveReadd',
                     'runningFrozenRunning', 'closeWhileFrozen', 'preconnectSixAccepted',
                     'preconnectDuplicateRejected', 'preconnectSeventhRejected',
                     'preconnectBadSocketCountRejected', 'preconnectUnsupportedSchemeRejected')
    assert all(checks.get(key) is True for key in required_true), checks
    for key in ('fastStatus', 'aggressiveStatus', 'concurrentPurgeStatus', 'emptyProcessPurgeStatus'):
        assert checks.get(key) in (1, 2), checks
    assert checks.get('fastElapsedMicroseconds', 0) > 0 and checks.get('aggressiveElapsedMicroseconds', 0) > 0 and \
           checks.get('emptyProcessPurgeElapsedMicroseconds', 0) > 0, checks
    assert checks.get('fastMeasurements') == (checks.get('fastStatus') == 1), checks
    assert checks.get('aggressiveMeasurements') == (checks.get('aggressiveStatus') == 1), checks
    assert all(listener.count > 0 for listener in args.listeners[:6]), checks
    assert checks['guiSecondsIncludingCleanup'] < 54, checks
    print('Engine r17 smoke: freeze, purge and preconnect checks passed; clean normal quit; %.2f s including cleanup' %
          checks['guiSecondsIncludingCleanup'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    args = parser.parse_args()
    validation.validate_bundle(args.app.resolve(), args.output.resolve())
    if not args.phase:
        assert not (args.output / 'data/perf-state.json').exists(), 'Use a fresh synthetic root'
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
            '--app', str(args.app.resolve()), '--output', str(args.output.resolve()), '--phase'], check=True)
        return

    args.http = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    args.http_port = args.http.server_address[1]
    args.listeners = [SocketListener() for _ in range(7)]
    try:
        phase(args)
    finally:
        args.http.shutdown()
        args.http.server_close()
        for listener in args.listeners:
            listener.close()


if __name__ == '__main__':
    main()
