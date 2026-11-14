#!/usr/bin/env python3
"""Qualify background media session plumbing (state and play/pause from the model) in a confined bundle."""
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

MEDIA_PAGE = b'''<!doctype html><title>Media fixture</title><script>
let audio=new Audio('/tone.wav'), nextCount=0, previousCount=0;
audio.loop=true;
function startMedia(){
  navigator.mediaSession.metadata=new MediaMetadata({title:'Synthetic title',artist:'Synthetic artist',
    artwork:[{src:location.origin+'/art.svg',sizes:'64x64',type:'image/svg+xml'}]});
  navigator.mediaSession.setActionHandler('play',()=>audio.play());
  navigator.mediaSession.setActionHandler('pause',()=>audio.pause());
  navigator.mediaSession.setActionHandler('seekto',d=>audio.currentTime=d.seekTime);
  navigator.mediaSession.setActionHandler('nexttrack',()=>nextCount++);
  navigator.mediaSession.setActionHandler('previoustrack',()=>previousCount++);
  audio.play();
}
</script><p>Synthetic media page</p>'''


def tone():
    # Digital silence: nothing reaches the speakers, so the tab reports not audible.
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
        elif self.path == '/art.svg':
            body = b'<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="green"/></svg>'
            content_type = 'image/svg+xml'
        elif self.path == '/media':
            body = MEDIA_PAGE
        else:
            body = b'<!doctype html><title>Other tab</title><p>Synthetic page</p>'
        self.send_response(status)
        for name, value in extra.items(): self.send_header(name, value)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    lab.APP = args.app.resolve()
    data = root / 'data'; state = data / 'perf-state.json'; control = data / 'perf-command.json'
    nonce = str(time.monotonic_ns())

    def timeout(*_):
        raise TimeoutError('60-second GUI lease')
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(55)
    started = time.monotonic()
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
                command = {'command': 'media-session', 'nonce': nonce, 'url': f'http://127.0.0.1:{args.port}/'}
                temporary = data / 'perf-command.pending'
                temporary.write_text(json.dumps(command)); temporary.replace(control)
                deadline = time.monotonic() + 35
                while time.monotonic() < deadline:
                    try: result = json.loads(state.read_text())
                    except (OSError, ValueError): result = {}
                    if result.get('commandNonce') == nonce and 'mediaSession' in result:
                        checks = result['mediaSession']; break
                    time.sleep(.05)
                else: raise TimeoutError('Media session probe')
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=5)
    signal.alarm(0)
    checks['guiSeconds'] = time.monotonic() - started
    checks['cleanExit'] = process.returncode == 0 and not owner.remaining and not owner.forced_signals
    (root / 'verification.json').write_text(json.dumps(checks, indent=2) + '\n')
    for line in checks.get('log', []): print(line)
    assert checks['cleanExit'], checks
    assert checks['foregroundPlaying'] and checks['foregroundExcluded'], checks
    assert checks['backgroundIsMediaTab'], checks
    session = checks['background'][0]
    assert session['title'] == 'Synthetic title' and session['artist'] == 'Synthetic artist', checks
    assert session['artwork'] == 'art.svg' and session['playback'] == 'playing', checks
    assert set(session['actions']) == {0, 1, 2, 3, 4}, checks
    assert checks['pauseResult'] == 'performed' and checks['modelPaused'], checks
    assert checks['playerAfterPause']['paused'] is True, checks
    assert checks['playResult'] == 'performed' and checks['modelPlaying'], checks
    assert checks['playerAfterPlay']['paused'] is False, checks
    assert checks['nextResult'] == 'performed' and checks['previousResult'] == 'performed', checks
    assert checks['playerAfterTracks']['next'] == 1 and checks['playerAfterTracks']['previous'] == 1, checks
    assert checks['mutedRemoved'] and checks['unmutedRestored'], checks
    assert checks['selectedExcluded'] and checks['stillTracked'] and checks['endedRemoved'], checks
    print('Background media session smoke passed; %.2f s GUI lease' % checks['guiSeconds'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    if args.phase:
        phase(args); return
    assert not (root / 'data/perf-state.json').exists(), 'Use a fresh synthetic root'
    Fixture.wav = tone()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
                        '--app', str(args.app.resolve()), '--output', str(root), '--phase',
                        '--port', str(server.server_port)], check=True)
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
