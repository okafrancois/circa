#!/usr/bin/env python3
"""Confined Calendar session/hover acceptance with invented rows and window-only recording."""
import argparse
import base64
import datetime
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
from urllib.parse import urlparse, parse_qs

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('calendar_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    starts = [(datetime.datetime.now().astimezone() + datetime.timedelta(minutes=m)).replace(second=0, microsecond=0) for m in [3, 65, 125]]
    counts = {}
    titles = ['📅 Kickoff meeting', 'Design workshop', 'Focus time']

    def do_GET(self):
        path = urlparse(self.path)
        self.counts[path.path] = self.counts.get(path.path, 0) + 1
        status, cookie = 200, False
        if path.path in ['/seed', '/notes', '/tasks']:
            body = '<html><title>Synthetic calendar</title><link rel="icon" href="/calendar.svg" type="image/svg+xml"><body style="font:16px system-ui;padding:40px;background:#fafafa;color:#555">Calendar fixture</body></html>'
            cookie = True
        elif path.path == '/calendar.svg':
            payload = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect x="2" y="2" width="28" height="28" rx="4" fill="#4285f4"/><path d="M7 9h18v17H7z" fill="white"/><path d="M7 26h18v4H7z" fill="#34a853"/><path d="M25 9h5v17h-5z" fill="#fbbc04"/><text x="16" y="22" text-anchor="middle" font-family="sans-serif" font-weight="bold" font-size="13" fill="#4285f4">15</text></svg>'
            self.send_response(200); self.send_header('Content-Type', 'image/svg+xml'); self.end_headers(); self.wfile.write(payload); return
        elif 'calendar-fixture=yes'  not in self.headers.get('Cookie', ''):
            status, body = 404, '<html><body>Signed out</body></html>'
        elif path.path == '/calendar/u/0/r':
            body = '<html><body><a href="https://accounts.google.com/SignOutOptions" aria-label="Google Account: Synthetic (fixture@example.invalid)">Account</a></body></html>'
        elif path.path == '/calendar/u/0/r/day':
            tuples = []
            for i, start in enumerate(self.starts):
                t = [None] * 83
                t[0] = f'fixture{i}'
                t[35] = [None, [start.timestamp() * 1000]]
                t[36] = [None, [(start + datetime.timedelta(minutes=[45, 60, 90][i])).timestamp() * 1000]]
                t[57] = [[[1, 'https://meet.google.com/abc-defg-hij']]] if i == 0 else []
                tuples.append([None, None, None, t])
            bootstrap = [None] * 40
            bootstrap[39] = [None, [['fixture@example.invalid', tuples]]]
            body = '<html><script id="initialdata" type="application/json">' + json.dumps(bootstrap) + '</script></html>'
        elif path.path == '/calendar/u/0/htmlembed':
            query = parse_qs(path.query)
            if query.get('src') != ['fixture@example.invalid'] or query.get('mode') != ['AGENDA']:
                status, body = 400, '<html></html>'
            else:
                now = datetime.datetime.now().astimezone()
                rows = []
                for i, start in enumerate(self.starts):
                    eid = base64.b64encode(f"fixture{i} opaque-calendar".encode()).decode()
                    stamp = start.strftime('%I:%M%p').lstrip('0').lower()
                    rows.append(f'<tr class="event"><td class="event-time">{stamp}</td><td class="event-summary"><a class="event-link" href="https://calendar.google.com/calendar/u/0/event?eid={eid}">{self.titles[i]}</a></td></tr>')
                body = '<html><body><div class="date">' + now.strftime('%a %b %d, %Y') + '</div><table class="events">' + ''.join(rows) + '</table></body></html>'
        else:
            status, body = 404, '<html></html>'
        payload = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        if cookie:
            self.send_header('Set-Cookie', 'calendar-fixture=yes; Path=/; SameSite=Lax; HttpOnly')
        self.end_headers()
        self.wfile.write(payload)


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    if subprocess.run([str(root / 'verify-window')], check=False).returncode != 0:
        raise RuntimeError('The GUI session is locked; no test bundle was launched')
    validation.lab.APP = args.app.resolve()
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    for name in ['perf-state.json', 'calendar-window.txt']:
        (data / name).unlink(missing_ok=True)
    started = time.monotonic()
    def expired(*_):
        raise TimeoutError('Calendar GUI lease expired')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(55)
    (root / "capture.mov").unlink(missing_ok=True)
    recording = None
    with validation.lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(args.app / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--perf-probe', f'--orbit-data-root={data}'], stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 12
                while True:
                    assert process.poll() is None
                    try:
                        ready = json.loads(state.read_text())
                    except (OSError, ValueError):
                        ready = {}
                    if ready.get('interactiveUptime') and ready.get('windowNumber') and ready.get('pid') == process.pid:
                        break
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                nonce = str(time.monotonic_ns())
                control.write_text(json.dumps({'command': 'window-freeze-2', 'step': 'calendar-preview', 'base': f'http://127.0.0.1:{args.port}', 'nonce': nonce, 'appearance': args.appearance}))
                deadline = time.monotonic() + 35
                while time.monotonic() < deadline:
                    if not args.no_record and recording is None and (data / 'calendar-window.txt').exists():
                        window = int((data / 'calendar-window.txt').read_text())
                        # The in-process probe verifies CGWindowOwnerPID before publishing this ID
                        # and before each synthetic event. Refuse a dead or replaced process.
                        assert process.poll() is None
                        subprocess.run([str(root / 'verify-window'), str(process.pid), str(window)], check=True)
                        # PID-scoped Accessibility activation, after live window-owner validation.
                        subprocess.run(['/usr/bin/osascript', '-e',
                            f'tell application "System Events" to set frontmost of first application process whose unix id is {process.pid} to true'],
                            check=True, timeout=4, stdout=out, stderr=err)
                        recording = subprocess.Popen(['/usr/sbin/screencapture', '-x', '-v', '-V', '13', '-l', str(window), str(root / 'capture.mov')], stdout=out, stderr=err)
                    try:
                        result = json.loads(state.read_text())
                    except (ValueError, OSError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'windowFreeze2' in result:
                        checks = result['windowFreeze2']
                        break
                    time.sleep(.05)
                else:
                    raise TimeoutError('Calendar acceptance')
                if recording is not None:
                    assert recording.wait(timeout=10) == 0, "Window recording failed"
            finally:
                if recording is not None and recording.poll() is None:
                    recording.terminate(); recording.wait(timeout=3)
                control.write_text('{"command":"quit"}')
                process.wait(timeout=4)
    signal.alarm(0)
    report = {'result': checks, 'guiSeconds': time.monotonic() - started, 'cleanShutdown': process.returncode == 0 and not owner.remaining and not owner.forced_signals}
    (root / 'verification.json').write_text(json.dumps(report, indent=2))
    assert checks.get('passed') and report['cleanShutdown'], report
    print(json.dumps(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--no-record', action='store_true')
    parser.add_argument('--port', type=int)
    parser.add_argument('--appearance', default='light', choices=['light', 'dark'])
    args = parser.parse_args()
    if args.phase:
        phase(args)
        return
    helper = args.output.resolve() / 'verify-window.swift'
    helper.write_text('import AppKit\nimport CoreGraphics\nif CommandLine.arguments.count == 1 { exit((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true ? 2 : 0) }\nlet pid = Int32(CommandLine.arguments[1])!\nlet id = UInt32(CommandLine.arguments[2])!\nlet entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []\nguard entries.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowNumber as String] as? UInt32) == id }) else { exit(1) }\n')
    subprocess.run(['/usr/bin/swiftc', str(helper), '-o', str(args.output.resolve() / 'verify-window')], check=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__, '--app', str(args.app.resolve()), '--output', str(args.output.resolve()), '--phase', '--port', str(server.server_port), '--appearance', args.appearance] + (['--no-record'] if args.no_record else []), check=True)
    finally:
        server.shutdown(); server.server_close(); thread.join()
        (args.output / 'fixture-requests.json').write_text(json.dumps(Fixture.counts, indent=2))
        info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
        identifier = info['CFBundleIdentifier']
        if info.get('OrbitSyntheticBundle') is True and identifier.startswith('lab.orbit.orbit.'):
            for command in [['/usr/bin/tccutil', 'reset', 'All', identifier],
                            ['/usr/bin/defaults', 'delete', identifier],
                            ['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(args.app)]]:
                subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


if __name__ == '__main__':
    main()
