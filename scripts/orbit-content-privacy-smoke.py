#!/usr/bin/env python3
"""Check browser window privacy in a confined synthetic bundle.

Phase `run`: a normal and a private window side by side on loopback fixture pages. Each window is
captured on its own (`screencapture -l <window id>`) for a few seconds: the normal window must be
captured, the private window must stay out of the capture. Phase `restore`: a relaunch on the same
root restores the normal window's tab from Circa's own session, while macOS keeps no saved window
state for the bundle.

Build the bundle with
  python3 scripts/orbit-app.py build --synthetic --bundle-id lab.orbit.orbit.local-secrets-windows \
      --synthetic-root <output>/data --output <app>
"""
import argparse
import importlib.util
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[1]
BUNDLE_ID = 'lab.orbit.orbit.local-secrets-windows'
PAGES = {
    '/normal': ('Normal window', '#2f6fdf'),
    '/private': ('Private window', '#7a3fd0'),
}


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        title, color = PAGES.get(self.path, ('Fixture', '#444'))
        body = (f'<!doctype html><title>{title}</title><body style="margin:0;font:600 34px -apple-system;'
                f'background:{color};color:white;display:flex;align-items:center;justify-content:center;height:100vh">'
                f'<div>{title}<div style="font-size:16px;font-weight:400;margin-top:12px">Synthetic page</div></div>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def validate_bundle(app, data):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info.get('CFBundleIdentifier') == BUNDLE_ID
    assert info.get('OrbitSyntheticBundle') is True and info.get('OrbitUseMockKeychain') is True
    assert info.get('OrbitDataRoot') == str(data)
    assert json.loads((data / '.orbit-synthetic-root').read_text()) == {
        'bundleID': BUNDLE_ID, 'owner': os.getuid(), 'version': 1}


WINDOW_HELPER = """import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let id = UInt32(CommandLine.arguments[2])!
let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
guard entries.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowNumber as String] as? UInt32) == id }) else { exit(1) }
"""


def owns_window(helper, pid, number):
    """The window server, not the test bundle, says which process owns a window (never by name)."""
    return subprocess.run([str(helper), str(pid), str(number)], timeout=10).returncode == 0


def capture(number, destination):
    destination.unlink(missing_ok=True)
    result = subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(number), str(destination)],
                            capture_output=True, text=True, timeout=10)
    return destination.is_file() and destination.stat().st_size > 0, result.returncode, (result.stderr or '').strip()[:200]


def phase(args):
    root, app = args.output.resolve(), args.app.resolve()
    data = root / 'data'
    validate_bundle(app, data)
    spec = importlib.util.spec_from_file_location('privacy_lab', REPO / 'scripts/orbit-chromium-lab.py')
    lab = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lab)
    lab.APP = app
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    state.unlink(missing_ok=True)
    control.unlink(missing_ok=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_address[1]}'
    helper = root / 'verify-window'
    frames = root / 'frames'
    frames.mkdir(exist_ok=True)
    command = [str(app / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--orbit-data-root=' + str(data), '--perf-probe']
    started = time.monotonic()

    def timeout(*_):
        raise TimeoutError('55-second GUI lease')

    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(55)
    summary = {'phase': args.phase}
    with lab.OwnedProcessRun() as owner:
        with (root / (args.phase + '-stdout.log')).open('w') as out, (root / (args.phase + '-stderr.log')).open('w') as err:
            process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)

            def request(values):
                nonce = str(time.monotonic_ns())
                pending = data / 'command.pending'
                pending.write_text(json.dumps(dict(values, nonce=nonce, command='content-privacy')))
                pending.replace(control)
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    try:
                        result = json.loads(state.read_text())
                        if result.get('commandNonce') == nonce:
                            return result['contentPrivacy']
                    except (FileNotFoundError, json.JSONDecodeError, KeyError):
                        pass
                    assert process.poll() is None, 'Synthetic process exited before response'
                    time.sleep(.05)
                raise TimeoutError('Synthetic command response')

            try:
                deadline = time.monotonic() + 15
                while True:
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    try:
                        ready = json.loads(state.read_text())
                    except (FileNotFoundError, json.JSONDecodeError):
                        ready = {}
                    if ready.get('interactiveUptime') and ready.get('windowNumber') and ready.get('browsers', 0) > 0:
                        break
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                if args.phase == 'run':
                    opened = request({'step': 'open', 'normal': base + '/normal', 'private': base + '/private'})
                    summary['windows'] = opened['windows']
                    normal = next(w for w in opened['windows'] if not w['private'])
                    private = next(w for w in opened['windows'] if w['private'])
                    # Only this test bundle's own windows are captured.
                    for window in (normal, private):
                        assert owns_window(helper, process.pid, window['number']), 'Window does not belong to the test bundle'
                    time.sleep(1.0)
                    results = []
                    for index in range(int(args.seconds * 4)):
                        row = {}
                        for kind, window in (('normal', normal), ('private', private)):
                            assert owns_window(helper, process.pid, window['number'])
                            captured, status, message = capture(window['number'], frames / f'{kind}-{index:03d}.png')
                            row[kind] = {'captured': captured, 'status': status, 'message': message}
                        results.append(row)
                        time.sleep(.25)
                    summary['captures'] = {
                        'frames': len(results),
                        'normalCaptured': sum(r['normal']['captured'] for r in results),
                        'privateCaptured': sum(r['private']['captured'] for r in results),
                        'privateStatus': sorted({r['private']['status'] for r in results}),
                        'privateMessages': sorted({r['private']['message'] for r in results}),
                    }
                    summary['afterClose'] = request({'step': 'close-private'})['windows']
                else:
                    summary['windows'] = request({})['windows']
            finally:
                try:
                    if process.poll() is None:
                        control.write_text('{"command":"quit"}')
                        process.wait(timeout=10)
                finally:
                    signal.alarm(0)
                    server.shutdown()
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    saved_state = Path.home() / 'Library/Saved Application State' / (BUNDLE_ID + '.savedState')
    summary['macosSavedState'] = saved_state.exists()
    summary['seconds'] = round(time.monotonic() - started, 2)
    (root / (args.phase + '-verification.json')).write_text(json.dumps(summary, indent=2) + '\n')
    assert all(not w['restorable'] for w in summary['windows']), 'A browser window is restorable by macOS'
    if args.phase == 'run':
        assert normal['sharingType'] == 1 and private['sharingType'] == 0, 'Unexpected sharing types'
        assert summary['captures']['normalCaptured'] == summary['captures']['frames'], 'Normal window not captured'
        print(json.dumps(summary['captures']))
    else:
        tabs = [url for w in summary['windows'] if not w['private'] for url in w['tabs']]
        assert any(url.endswith('/normal') for url in tabs), 'Normal session was not restored'
        assert not any(w['private'] for w in summary['windows']), 'A private window was restored'
    assert not summary['macosSavedState'], 'macOS stored window state for the bundle'
    print(f"content privacy {args.phase}: passed in {summary['seconds']} s")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='Bundle must bake <output>/data as its synthetic root')
    parser.add_argument('--phase', choices=['run', 'restore'], required=True)
    parser.add_argument('--seconds', type=float, default=6)
    parser.add_argument('--locked', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    validate_bundle(args.app.resolve(), args.output.resolve() / 'data')
    helper = args.output.resolve() / 'verify-window'
    if not helper.exists():
        source = args.output.resolve() / 'verify-window.swift'
        source.write_text(WINDOW_HELPER)
        subprocess.run(['/usr/bin/swiftc', str(source), '-o', str(helper)], check=True)
    if args.locked:
        phase(args)
    else:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__, '--app',
                        str(args.app.resolve()), '--output', str(args.output.resolve()), '--phase', args.phase,
                        '--seconds', str(args.seconds), '--locked'], check=True)


if __name__ == '__main__':
    main()
