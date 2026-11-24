#!/usr/bin/env python3
"""chrome.action.openPopup() from page content in a confined bundle (issue #25).

The static MV3 fixture native/OrbitChromium/Tests/ApiPopupExtension adds an inline "Unlock"
button to a loopback login page; a trusted click asks its service worker to call
chrome.action.openPopup(). The probe runs three requests in one bounded GUI session: unpinned
and pinned action with the sidebar shown (popup anchored to the shell's action anchor) and the
hidden-sidebar case (engine-owned detached window). Each time it checks the promise, the visible
popup, that no activeTab grant was made, that a second request while the popup is up is refused,
and that Escape dismisses it.

--clip records only the unpinned request as frames of the test window (its child popup included,
nothing else on screen) and encodes a short silent H.264 clip with a JPEG poster.

--expect fixed requires all of that; --expect broken requires the pre-r27 failure ("Browser
window has no toolbar.", no popup), which is how the same bundle proves the engine difference.
"""
import argparse
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('api_popup_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)
lab = validation.lab
EXTENSION = REPO / 'native/OrbitChromium/Tests/ApiPopupExtension'
PAGE = (b'<!doctype html><meta charset="utf-8"><title>Synthetic sign-in</title>'
        b'<body style="font:16px system-ui;margin:40px"><label>Synthetic account '
        b'<input name="account" autocomplete="off"></label></body>')
NO_TOOLBAR = 'rejected: Browser window has no toolbar.'
FAILED = 'rejected: Failed to open popup.'
# The popup takes key focus, so Chrome's own window check may refuse a second request first.
INACTIVE = 'rejected: Could not find an active browser window.'


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.client_address[0] != '127.0.0.1':
            self.send_error(403)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(PAGE)


def failures(checks, expect, clip=False):
    """The unmet expectations of one run, empty when it passed."""
    problems = []
    if checks.get('contentScriptReady') is not True:
        problems.append('content script not ready')
    for name in (('unpinned',) if clip else ('unpinned', 'pinned', 'hiddenSidebar')):
        entry = checks.get(name, {})
        def need(condition, message):
            if not condition:
                problems.append('%s: %s (%r)' % (name, message, entry))
        need(entry.get('sidebarVisible') is (name != 'hiddenSidebar'), 'sidebar state')
        need(entry.get('trusted') == 'true', 'the click must be a trusted page event')
        need(entry.get('pinned') is (name != 'unpinned'), 'pin state')
        if expect == 'broken':
            need(entry.get('result') == NO_TOOLBAR, 'expected the hosted-Browser failure')
            need(entry.get('popupVisible') is False, 'no popup expected')
            continue
        need(entry.get('result') == 'resolved', 'openPopup() did not resolve')
        need(entry.get('popupVisible') is True and entry.get('popupKey') is True, 'popup not shown with focus')
        need(entry.get('urlVisible') == 'false', 'the API path granted tab access')
        need(entry.get('secondResult') in (FAILED, INACTIVE) and entry.get('popupSurvivedSecond') is True,
             'a second request while the popup is up must be refused')
        need(entry.get('dismissedByEscape') is True, 'Escape did not dismiss the popup')
        need(entry.get('popupTitled') is (name == 'hiddenSidebar'), 'anchored bubble or detached window')
    return problems


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    lab.APP = args.app.resolve()
    data = root / 'data'
    control = data / 'perf-command.json'
    state = data / 'perf-state.json'
    def expired(*_):
        raise TimeoutError('Bounded API popup GUI lease')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(50)  # Inside the 60 s GUI slot, quit and cleanup included.
    assert not state.exists(), 'Use a fresh synthetic root'
    assert EXTENSION.is_dir() and not EXTENSION.is_symlink()
    with lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
                '--perf-probe', f'--orbit-data-root={data}', '--load-extension=' + str(EXTENSION)],
                stdout=out, stderr=err, stdin=subprocess.DEVNULL,
                env=dict(os.environ, ORBIT_EXTENSION_DIAGNOSTICS='1'))
            result = {}
            try:
                deadline = time.monotonic() + 15
                while True:
                    assert process.poll() is None, 'Exited during startup'
                    assert time.monotonic() < deadline, 'Startup timeout'
                    try:
                        ready = json.loads(state.read_text())
                    except (OSError, ValueError):
                        ready = {}
                    if ready.get('pid') == process.pid and ready.get('interactiveUptime'):
                        break
                    time.sleep(.05)
                nonce = str(time.monotonic_ns())
                command = {'command': 'extension-controls', 'action': 'api-popup', 'nonce': nonce,
                           'base': f'http://127.0.0.1:{args.port}/'}
                if args.clip:
                    command['clip'] = 'true'
                pending = data / 'command.pending'
                pending.write_text(json.dumps(command))
                pending.replace(control)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and process.poll() is None:
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'extensionControls' in result:
                        break
                    time.sleep(.05)
                checks = result.get('extensionControls', {})
                (root / 'verification.json').write_text(json.dumps(checks, indent=2, sort_keys=True) + '\n')
                assert process.poll() is None, f'Exited during the probe: {process.returncode}'
                problems = failures(checks, args.expect, args.clip)
                assert not problems, problems
            finally:
                if process.poll() is None:
                    control.write_text('{"command":"quit"}')
                    process.wait(timeout=5)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    print('API popup smoke passed:', args.expect)


def encode_clip(root):
    """frames.json (file, seconds) from the probe -> clip.mp4 (H.264, silent, <= 1440 px) and poster.jpg."""
    directory = root / 'data/clip'
    frames = json.loads((directory / 'frames.json').read_text())
    assert len(frames) >= 10, 'Too few frames'
    lines = []
    for index, frame in enumerate(frames):
        following = frames[index + 1]['t'] if index + 1 < len(frames) else frame['t'] + 0.5
        lines += ["file '%s'" % (directory / frame['file']), 'duration %.3f' % max(following - frame['t'], 0.04)]
    lines.append("file '%s'" % (directory / frames[-1]['file']))
    (directory / 'concat.txt').write_text('\n'.join(lines) + '\n')
    clip, poster = root / 'clip.mp4', root / 'poster.jpg'
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(directory / 'concat.txt'),
                    '-vf', 'scale=1440:-2:flags=lanczos,fps=30,format=yuv420p', '-an', '-c:v', 'libx264',
                    '-preset', 'slow', '-crf', '26', '-movflags', '+faststart', str(clip)], check=True)
    shown = next((frame for frame in frames if frame.get('popup')), frames[len(frames) // 2])
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(directory / shown['file']),
                    '-vf', 'scale=1440:-2:flags=lanczos', '-q:v', '3', str(poster)], check=True)
    duration = frames[-1]['t'] - frames[0]['t'] + 0.5
    assert duration <= 15 and clip.stat().st_size <= 3 * 1024 * 1024, (duration, clip.stat().st_size)
    print('clip', clip, '%.1f s' % duration, clip.stat().st_size, 'bytes; poster', poster)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expect', choices=['fixed', 'broken'], default='fixed')
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    parser.add_argument('--clip', action='store_true', help='Record the unpinned request only (needs ffmpeg)')
    args = parser.parse_args()
    validation.validate_bundle(args.app.resolve(), args.output.resolve())
    if args.phase:
        phase(args)
        return
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run(['/usr/bin/lockf', '-t', '1', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
                        '--app', str(args.app.resolve()), '--output', str(args.output.resolve()), '--phase',
                        '--expect', args.expect, '--port', str(server.server_port)] + (['--clip'] if args.clip else []),
                       check=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    if args.clip:
        encode_clip(args.output.resolve())


if __name__ == '__main__':
    main()
