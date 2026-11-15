#!/usr/bin/env python3
"""Record the sidebar media player walkthrough in a confined synthetic bundle.

Two local MediaSession pages play silent audio; the in-app probe walks through appearance,
hover, play/pause, a two-card stack, a pause from the page, a Space switch, Back to Tab and the
close button while ffmpeg records the window at 60 fps under the shared GUI lock.
"""
import argparse
import importlib.util
import io
import json
from pathlib import Path
import signal
import struct
import subprocess
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('media_bundle_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab

PAGE = '''<!doctype html><title>{title}</title><link rel="icon" href="/icon-{key}.svg"><script>
let audio=new Audio('/tone.wav');
audio.loop=true;
function startMedia(){{
  navigator.mediaSession.setActionHandler('play',()=>audio.play());
  navigator.mediaSession.setActionHandler('pause',()=>audio.pause());
  audio.play();
}}
</script><p>{title}</p>'''
ICON = ('<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" rx="7" fill="{color}"/>'
        '<circle cx="16" cy="16" r="6" fill="white"/></svg>')
PAGES = {'a': ('Evening Rehearsal - Synthetic Album', '#3F7BF5'), 'b': ('Morning Session - Synthetic Album', '#E2574C')}


def tone():
    # Digital silence: nothing reaches the speakers.
    output = io.BytesIO()
    with wave.open(output, 'wb') as audio:
        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(8000)
        audio.writeframes(struct.pack('<h', 0) * (8000 * 20))
    return output.getvalue()


class Fixture(BaseHTTPRequestHandler):
    wav = b''

    def log_message(self, *_):
        pass

    def do_GET(self):
        content_type, status, extra = 'text/html', 200, {}
        key = self.path.rsplit('-', 1)[-1].split('.')[0]
        if self.path == '/tone.wav':
            body, content_type = self.wav, 'audio/wav'
            extra['Accept-Ranges'] = 'bytes'
            header = self.headers.get('Range', '')
            if header.startswith('bytes='):
                first, _, last = header[6:].partition('-')
                first = int(first or 0); last = min(int(last) if last else len(body) - 1, len(body) - 1)
                status = 206
                extra['Content-Range'] = 'bytes %d-%d/%d' % (first, last, len(body))
                body = body[first:last + 1]
        elif self.path.startswith('/icon-') and key in PAGES:
            body, content_type = ICON.format(color=PAGES[key][1]).encode(), 'image/svg+xml'
        elif self.path.startswith('/media-') and key in PAGES:
            body = PAGE.format(title=PAGES[key][0], key=key).encode()
        else:
            body = b'<!doctype html><title>Synthetic Page</title><p>Synthetic page</p>'
        self.send_response(status)
        for name, value in extra.items(): self.send_header(name, value)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def idle_seconds():
    output = subprocess.run(['ioreg', '-c', 'IOHIDSystem'], capture_output=True, text=True).stdout
    for line in output.splitlines():
        if 'HIDIdleTime' in line:
            return int(line.rsplit('=', 1)[1].strip()) / 1e9
    return 0.0


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    lab.APP = args.app.resolve()
    data = root / 'data'; state = data / 'perf-state.json'; control = data / 'perf-command.json'
    nonce = str(time.monotonic_ns())

    def timeout(*_):
        raise TimeoutError('60-second GUI lease')
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(58)
    started = time.monotonic()
    recorder = None
    with lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--perf-probe',
                                    f'--orbit-data-root={data}'], stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 15
                while not state.exists():
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    if time.monotonic() > deadline: raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                command = {'command': 'media-player', 'nonce': nonce, 'url': f'http://127.0.0.1:{args.port}/',
                           'appearance': args.appearance, 'space': 'switch' if args.space_switch else ''}
                temporary = data / 'perf-command.pending'
                temporary.write_text(json.dumps(command)); temporary.replace(control)
                geometry_file = data / 'window.json'
                deadline = time.monotonic() + 25
                while not geometry_file.exists():
                    if time.monotonic() > deadline: raise TimeoutError('Probe window geometry')
                    time.sleep(.05)
                time.sleep(.1)
                geometry = json.loads(geometry_file.read_text())
                scale = geometry['scale']
                crop = [int(round(geometry[key] * scale)) for key in ('width', 'height', 'x', 'y')]
                movie = root / f'circa-{args.appearance}.mov'
                recorder = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'avfoundation',
                                             '-capture_cursor', '0', '-framerate', '60', '-pixel_format', 'bgr0',
                                             '-i', 'Capture screen 0:none', '-vf', 'crop=%d:%d:%d:%d' % tuple(crop),
                                             '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '8', '-pix_fmt', 'yuv444p',
                                             str(movie)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                            stderr=(root / 'ffmpeg.log').open('w'))
                time.sleep(1.0)
                recording_started = time.time() - 1.0
                (data / 'go').write_text('go')
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    try: result = json.loads(state.read_text())
                    except (OSError, ValueError): result = {}
                    if result.get('commandNonce') == nonce and 'mediaPlayer' in result:
                        checks = result['mediaPlayer']; break
                    time.sleep(.05)
                else: raise TimeoutError('Media player walkthrough')
            finally:
                if recorder and recorder.poll() is None:
                    recorder.stdin.write(b'q'); recorder.stdin.flush()
                    try: recorder.wait(timeout=10)
                    except subprocess.TimeoutExpired: recorder.kill()
                control.write_text('{"command":"quit"}')
                process.wait(timeout=20)
    signal.alarm(0)
    checks['guiSeconds'] = time.monotonic() - started
    checks['recordingStartedWall'] = recording_started
    checks['cleanExit'] = process.returncode == 0 and not owner.remaining and not owner.forced_signals
    (root / f'verification-{args.appearance}.json').write_text(json.dumps(checks, indent=2) + '\n')
    assert checks['cleanExit'], checks
    for key in ('appearOne', 'pausedFromCard', 'playingFromCard', 'appearTwo', 'stackExpanded', 'pageGreyed',
                'backToTab', 'closedCard', 'tabStays'):
        assert checks.get(key) is True, (key, checks)
    assert checks['pageAfterCardPause'].get('paused') is True and checks['pageAfterClose'].get('paused') is True, checks
    if args.space_switch:
        assert checks.get('followsSpace') is True and checks.get('secondSpaceDark') is (args.appearance == 'light'), checks
    print('Media player walkthrough (%s) passed; %.2f s GUI lease' % (args.appearance, checks['guiSeconds']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--appearance', choices=['light', 'dark'], default='light')
    parser.add_argument('--space-switch', action='store_true')
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--require-idle', type=float, default=0,
                        help='Record only after this many seconds without keyboard or pointer input (waits up to 10 min)')
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    if args.phase:
        phase(args); return
    assert not (root / 'data/perf-state.json').exists(), 'Use a fresh synthetic root'
    if args.require_idle:
        # The screen recording must not catch someone else working on this display.
        deadline = time.monotonic() + 600
        while idle_seconds() < args.require_idle:
            if time.monotonic() > deadline: raise TimeoutError('The display never became idle')
            time.sleep(2)
    Fixture.wav = tone()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        command = [sys.executable, __file__, '--app', str(args.app.resolve()), '--output', str(root), '--phase',
                   '--appearance', args.appearance, '--port', str(server.server_port)]
        if args.space_switch: command.append('--space-switch')
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock'] + command, check=True)
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
