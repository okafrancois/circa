#!/usr/bin/env python3
"""Qualify native security, permission, history and media APIs in a confined bundle."""
import argparse
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import signal
import ssl
import struct
import subprocess
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('security_bundle_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab


class Fixture(BaseHTTPRequestHandler):
    http_port = 0
    def log_message(self, *_):
        pass

    def do_GET(self):
        content_type = 'text/html'
        if self.path == '/tone.wav':
            output = io.BytesIO()
            with wave.open(output, 'wb') as audio:
                audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(8000)
                audio.writeframes(struct.pack('<h', 0) * 80000)
            body = output.getvalue(); content_type = 'audio/wav'
        elif self.path == '/art.svg':
            body = b'<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="green"/></svg>'
            content_type = 'image/svg+xml'
        elif self.path == '/mixed.js':
            body = b'globalThis.mixedExecuted=true;'; content_type = 'application/javascript'
        elif self.path == '/mixed':
            body = ('<!doctype html><title>Mixed fixture</title><script src="http://mixed.example.invalid:%d/mixed.js"></script>' % self.http_port).encode()
        elif self.path == '/media':
            body = b'''<!doctype html><title>Media fixture</title><script>
let audio=new Audio('/tone.wav'), nextCount=0,previousCount=0;
function startMedia(){
  navigator.mediaSession.metadata=new MediaMetadata({title:'Synthetic title',artist:'Synthetic artist',artwork:[{src:location.origin+'/art.svg',sizes:'64x64',type:'image/svg+xml'}]});
  navigator.mediaSession.setActionHandler('play',()=>audio.play());
  navigator.mediaSession.setActionHandler('pause',()=>audio.pause());
  navigator.mediaSession.setActionHandler('seekto',d=>audio.currentTime=d.seekTime);
  navigator.mediaSession.setActionHandler('nexttrack',()=>nextCount++);
  navigator.mediaSession.setActionHandler('previoustrack',()=>previousCount++);
  const updatePosition=()=>navigator.mediaSession.setPositionState({duration:audio.duration,playbackRate:1,position:audio.currentTime});
  if(Number.isFinite(audio.duration))updatePosition();else audio.onloadedmetadata=updatePosition;
  audio.play();
}
</script>'''
        else:
            body = b'<!doctype html><title>Security fixture</title><p>Synthetic page</p>'
        status = 200
        extra = {}
        if self.path == '/tone.wav':
            total = len(body)
            extra['Accept-Ranges'] = 'bytes'
            match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
            if match:
                first = int(match[1]); last = min(int(match[2]) if match[2] else total - 1, total - 1)
                if first > last:
                    status = 416; body = b''; extra['Content-Range'] = 'bytes */%d' % total
                else:
                    status = 206; body = body[first:last + 1]
                    extra['Content-Range'] = 'bytes %d-%d/%d' % (first, last, total)
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
        raise TimeoutError('45-second GUI lease')
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(35)
    started = time.monotonic()
    with lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
                '--perf-probe', '--orbit-security-fixture',
                f'--orbit-data-root={data}'], stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 12
                while not state.exists():
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    if time.monotonic() > deadline: raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                command = {'command': 'native-security', 'nonce': nonce,
                           'url': f'http://127.0.0.1:{args.port}/', 'tls': args.tls}
                temporary = data / 'perf-command.pending'
                temporary.write_text(json.dumps(command)); temporary.replace(control)
                deadline = time.monotonic() + 26
                while time.monotonic() < deadline:
                    try: result = json.loads(state.read_text())
                    except (OSError, ValueError): result = {}
                    if result.get('commandNonce') == nonce and 'nativeSecurity' in result:
                        checks = result['nativeSecurity']; break
                    time.sleep(.05)
                else: raise TimeoutError('Native security probe')
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=3)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    checks['guiSeconds'] = time.monotonic() - started
    (root / 'verification.json').write_text(json.dumps(checks, indent=2) + '\n')
    pins = json.loads((REPO / 'native/OrbitChromium/cef-patches/engine-r14/source.json').read_text())
    version = json.loads(checks['version'])
    assert version['product'] == 'Chrome/' + pins['chromium_tag'], checks
    assert version['revision'].lstrip('@') == pins['chromium_commit'], checks
    persisted = []
    profiles = list(data.rglob('Preferences'))
    assert profiles, 'Missing synthetic profile preferences'
    for path in profiles:
        preferences = json.loads(path.read_text())
        exceptions = preferences.get('profile', {}).get('content_settings', {}).get('exceptions', {})
        persisted.extend({'kind': kind, 'settings': value} for kind, value in exceptions.items()
                         if 'geolocation' in kind and value)
    (root / 'permission-persistence.json').write_text(json.dumps(persisted, indent=2) + '\n')
    assert not persisted, 'Unexpected persisted geolocation content setting'
    assert checks['onceInitialPrompts'] == 1 and checks['onceReloadPrompts'] == 2, checks
    assert checks['onceInitial']['value'] == 'granted' and checks['onceReload']['value'] == 'granted', checks
    assert checks['goBack'] and checks['historyBack'] and checks['invalidIndexRefused'], checks
    assert any(e['entered'] and e['origin'] == f'http://127.0.0.1:{args.port}' for e in checks['fullscreen']), checks
    assert any(not e['entered'] and e['origin'] == f'http://127.0.0.1:{args.port}' for e in checks['fullscreen']), checks
    cert = json.loads(checks['certificateSecurity'])
    assert cert['certificateError'] and cert['interstitial'] and cert['level'] == 5, checks
    mixed = json.loads(checks['mixedSecurity'])
    assert mixed['ranMixedContent'] and checks['mixedExecuted']['ran'], checks
    assert checks['idn'] == 'https://xn--pple-43d.com' and checks['asciiDisplay'] == 'example.invalid', checks
    media = json.loads(checks['media'])
    assert media['title'] == 'Synthetic title' and media['artist'] == 'Synthetic artist' and media['artwork'], checks
    assert media['position'] >= 0 and media['duration'] == 10, checks
    assert all(checks[k] for k in ('play', 'pause', 'seek', 'next', 'previous')), checks
    assert checks['pausedPlayer']['paused'] and not checks['playingPlayer']['paused'], checks
    assert json.loads(checks['mediaPaused'])['playbackState'] == 0, checks
    assert 1.9 <= checks['seekPlayer']['time'] <= 3, checks
    assert checks['mediaActions']['next'] == 1 and checks['mediaActions']['previous'] == 1, checks
    assert checks['securityEvents'] > 1 and checks['mediaEvents'] > 1, checks
    print('Native security smoke passed; clean normal shutdown; %.2f s GUI lease' % checks['guiSeconds'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    parser.add_argument('--tls')
    args = parser.parse_args()
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    if args.phase:
        phase(args); return
    assert not (root / 'data/perf-state.json').exists(), 'Use a fresh synthetic root'
    key, cert = root / 'tls-key.pem', root / 'tls-cert.pem'
    subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
        '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1', '-keyout', str(key), '-out', str(cert)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(key, 0o600)
    http = ThreadingHTTPServer(('127.0.0.1', 0), Fixture); Fixture.http_port = http.server_port
    tls = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    for server in (http, tls):
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
            '--app', str(args.app.resolve()), '--output', str(root), '--phase', '--port', str(http.server_port),
            '--tls', 'https://127.0.0.1:%d' % tls.server_port], check=True)
    finally:
        for server in (http, tls): server.shutdown(); server.server_close()
        key.unlink(missing_ok=True); cert.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
