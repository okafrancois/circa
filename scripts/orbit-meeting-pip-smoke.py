#!/usr/bin/env python3
"""Qualify automatic video PiP during a loopback call with fake media devices."""
import argparse
import importlib.util
import json
import plistlib
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('meeting_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    lab.APP = args.app.resolve()
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    state.unlink(missing_ok=True)
    control.unlink(missing_ok=True)
    nonce = str(time.monotonic_ns())

    def timeout(*_):
        raise TimeoutError('48-second GUI lease')

    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(48)
    started = time.monotonic()
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'lab.orbit.orbit.sec-permissions'
    with lab.OwnedProcessRun() as owner:
        with (root / f'{args.mode}-stdout.log').open('w') as out, (root / f'{args.mode}-stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS' / info['CFBundleExecutable']),
                '--use-mock-keychain', '--perf-probe', '--orbit-permissions-fixture', f'--orbit-data-root={data}'],
                stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 12
                while not state.exists():
                    assert process.poll() is None, 'Synthetic process exited; stop at the first crash'
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                pending = data / 'perf-command.pending'
                pending.write_text(json.dumps({'command': 'permissions', 'kind': 'pip', 'mode': args.mode,
                    'nonce': nonce, 'url': f'http://127.0.0.1:{args.port}/'}))
                pending.replace(control)
                deadline = time.monotonic() + 28
                while time.monotonic() < deadline:
                    assert process.poll() is None, 'Synthetic process exited; stop at the first crash'
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'permissions' in result:
                        checks = result['permissions']
                        break
                    time.sleep(.05)
                else:
                    raise TimeoutError('Meeting PiP probe')
            finally:
                if process.poll() is None:
                    control.write_text('{"command":"quit"}')
                    process.wait(timeout=3)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    checks['guiSeconds'] = time.monotonic() - started
    (root / f'{args.mode}.json').write_text(json.dumps(checks, indent=2) + '\n')
    assert checks['call']['call'] == 'active', checks
    assert checks['microphoneActive' if args.mode == 'microphone' else 'cameraActive'], checks
    assert checks['foreground']['pip'] is False, checks
    expected = args.mode not in ('site-off', 'global-off')
    assert checks['leftTab']['pip'] is expected, checks
    if expected:
        assert checks['offscreen'] is True, checks
        assert checks['spaceSent'] and checks['leftSent'] and checks['rightSent'], checks
        assert checks['afterSpace']['paused'] is True, checks
        # Native automatic controls currently omit seek buttons; record this engine limitation.
        if args.mode == 'manual':
            assert abs(checks['afterLeft']['time'] - checks['afterSpace']['time'] + 10) < 1, checks
            assert abs(checks['afterRight']['time'] - checks['afterSpace']['time']) < 1, checks
            assert checks['disabledWhileOpen']['pip'] is True, checks
        else:
            assert checks['disabledWhileOpen']['pip'] is False, checks
    print(f'{args.mode}: call/PiP checks passed, native key outcomes recorded; {checks["guiSeconds"]:.2f} s GUI lease')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--video', type=Path, required=True, help='Synthetic finite WebM fixture')
    parser.add_argument('--mode', choices=['camera', 'microphone', 'global-off', 'site-off', 'manual'], required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    if args.phase:
        phase(args)
        return
    validation.validate_bundle(args.app.resolve(), args.output.resolve())

    class Fixture(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == '/video.webm':
                body, kind = args.video.read_bytes(), 'video/webm'
            else:
                body = b'<!doctype html><title>Synthetic call</title><video src="/video.webm" muted playsinline onloadedmetadata="this.currentTime=20" style="width:640px;height:360px"></video>'
                kind = 'text/html'
            total = len(body)
            start, end = 0, total - 1
            requested_range = self.headers.get('Range', '') if kind == 'video/webm' else ''
            if requested_range.startswith('bytes='):
                first, last = requested_range[6:].split('-', 1)
                start = int(first or '0')
                end = min(int(last) if last else end, end)
                body = body[start:end + 1]
            self.send_response(206 if requested_range else 200)
            if requested_range:
                self.send_header('Content-Range', f'bytes {start}-{end}/{total}')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
            '--app', str(args.app.resolve()), '--output', str(args.output.resolve()),
            '--video', str(args.video.resolve()), '--mode', args.mode, '--phase', '--port', str(server.server_port)],
            check=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
