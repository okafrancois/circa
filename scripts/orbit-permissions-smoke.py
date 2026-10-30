#!/usr/bin/env python3
"""Qualify shell permission choices using loopback, fake media and a confined synthetic bundle."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('permissions_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        body = b'<!doctype html><title>Synthetic permissions</title><p>Loopback permission fixture</p>'
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
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    state.unlink(missing_ok=True)
    control.unlink(missing_ok=True)
    nonce = str(time.monotonic_ns())
    def timeout(*_):
        raise TimeoutError('50-second GUI lease')
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(50)
    started = time.monotonic()
    with (args.app / 'Contents/Info.plist').open('rb') as stream:
        executable = plistlib.load(stream)['CFBundleExecutable']
    with lab.OwnedProcessRun() as owner:
        with (root / f'{args.kind}-{args.mode}-stdout.log').open('w') as out, (root / f'{args.kind}-{args.mode}-stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS' / executable), '--use-mock-keychain',
                '--perf-probe', '--orbit-permissions-fixture', f'--orbit-data-root={data}'],
                stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 14
                while not state.exists():
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    if time.monotonic() > deadline: raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                command = {'command': 'permissions', 'nonce': nonce, 'kind': args.kind, 'mode': args.mode,
                           'url': f'http://127.0.0.1:{args.port}/'}
                temporary = data / 'perf-command.pending'
                temporary.write_text(json.dumps(command)); temporary.replace(control)
                deadline = time.monotonic() + 32
                while time.monotonic() < deadline:
                    try: result = json.loads(state.read_text())
                    except (OSError, ValueError): result = {}
                    if result.get('commandNonce') == nonce and 'permissions' in result:
                        checks = result['permissions']; break
                    time.sleep(.05)
                else: raise TimeoutError('Permission probe')
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=3)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    checks['guiSeconds'] = time.monotonic() - started
    checks['mode'] = args.mode
    (root / f'{args.kind}-{args.mode}.json').write_text(json.dumps(checks, indent=2) + '\n')
    if args.kind == 'captures':
        assert len(checks['captures']) == 12, checks
        print('12 prompt captures; %.2f s GUI lease' % checks['guiSeconds']); return
    assert checks['mixedMaskRefused'] and len(checks['maskAudit']) == 30 and len(checks['mediaMaskAudit']) == 4
    known = {2: 'camera', 4: 'other("clipboardRead")', 8: 'geolocation', 12: 'microphone', 15: 'notifications'}
    for entry in checks['maskAudit']:
        bit = int(entry['bit'])
        assert entry['kind'] == known.get(bit, f'other("cef-permission-{1 << bit}")'), entry
    for entry in checks['mediaMaskAudit']:
        bit = int(entry['bit'])
        assert entry['kind'] == {0: 'microphone', 1: 'camera'}.get(bit, f'other("cef-media-{1 << bit}")'), entry
    if args.mode == 'persistent':
        assert checks['initial']['value'] == 'granted' and checks['reload']['value'] == 'granted', checks
        assert checks['initial']['prompts'] == checks['reload']['prompts'] == 1 and checks['configuredOrigins'] == 1, checks
    else:
        keys = ['initial', 'reload', 'navigateBack', 'unload', 'discard', 'close', 'profile']
        assert checks['discarded'] and checks['discardRestored'] and checks['separateProfile'] and checks['configuredOrigins'] == 0, checks
        for count, key in enumerate(keys, 1):
            assert checks[key]['prompts'] == count, (key, checks)
            expected = 'default' if args.kind == 'notifications' else 'granted'
            assert checks[key]['value'] == expected, (key, checks)
        for count, key in enumerate(['notNow', 'notNowReload', 'notNowNavigate'], 8):
            assert checks[key]['prompts'] == count and checks[key]['value'] != 'granted', (key, checks)
        exceptions = []
        for path in data.rglob('Preferences'):
            prefs = json.loads(path.read_text())
            assert not prefs.get('profile', {}).get('content_settings', {}).get('permission_actions'), 'Saved permission action preference'
            assert not prefs.get('profile', {}).get('one_time_permission_prompts_decided_count'), 'Saved transient prompt count'
            for kind, entries in prefs.get('profile', {}).get('content_settings', {}).get('exceptions', {}).items():
                if entries and kind in ('geolocation', 'geolocation_with_options', 'media_stream_camera', 'media_stream_mic', 'notifications', 'permission_actions_history', 'permission_autoblocking_data'):
                    exceptions.append(kind)
        permission_files = list(data.rglob('*.site-permissions.json'))
        assert not exceptions, exceptions
        assert all(not json.loads(path.read_text())['entries'] for path in permission_files), permission_files
        checks['persistedExceptions'] = exceptions
        (root / f'{args.kind}-{args.mode}.json').write_text(json.dumps(checks, indent=2) + '\n')
    print('%s %s passed; %.2f s GUI lease' % (args.kind, args.mode, checks['guiSeconds']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    parser.add_argument('--kind', default='geolocation')
    parser.add_argument('--mode', default='once')
    args = parser.parse_args()
    if args.phase:
        phase(args); return
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
            '--app', str(args.app.resolve()), '--output', str(root), '--phase', '--port', str(server.server_port),
            '--kind', args.kind, '--mode', args.mode], check=True, timeout=60)
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
