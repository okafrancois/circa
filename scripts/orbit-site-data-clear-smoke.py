#!/usr/bin/env python3
"""Qualify profile-wide site data clearing and profile removal in a confined synthetic bundle.

Build the synthetic bundle from the hidden smoke app with `--synthetic-root <output>/data`, then:
  python3 scripts/orbit-site-data-clear-smoke.py --app <bundle> --output <output>
With `--clip`, the bundle is the product app built with the bundle id lab.orbit.orbit.site-data-clear:
the Settings flow runs in a visible window, recorded by window ID (PID verified), with captures of
the page window before and after.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('site_data_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab

REQUIRED = {'seed', 'seeded-state', 'http-cache-seeded', 'clear', 'cleared-all-origins', 'http-cache-cleared',
            'other-profile-intact', 'tab-keeps-working', 'origin-without-tab', 'synthetic-cache-inside-profile', 'profile-removed'}


STATUS_PAGE = b"""<!doctype html><meta charset=utf-8><title>Synthetic Account</title>
<style>body{font:17px -apple-system,sans-serif;margin:0;display:grid;place-items:center;height:100vh;background:#f4f4f6;color:#1d1d1f}
.card{background:#fff;border-radius:14px;padding:32px 40px;box-shadow:0 2px 12px #0001;min-width:360px}
h1{font-size:22px;margin:0 0 18px}p{margin:8px 0}.on{color:#1a7f37}.off{color:#b42318}</style>
<body data-state=""><div class=card><h1>Synthetic Account</h1><p id=s></p><p id=l></p></div>
<script>
if (location.search.includes('seed=1')) {
  document.cookie = 'session=connected; path=/; max-age=3600';
  localStorage.setItem('draft', 'Synthetic draft');
  history.replaceState(null, '', '/status');
}
function render() {
  const signed = document.cookie.includes('session=connected'), draft = localStorage.getItem('draft');
  s.textContent = signed ? 'Signed in (session cookie)' : 'Signed out'; s.className = signed ? 'on' : 'off';
  l.textContent = draft ? 'Local storage: ' + draft : 'Local storage: empty'; l.className = draft ? 'on' : 'off';
  document.body.dataset.state = (signed ? 'signed-in' : 'signed-out') + ',' + (draft ? 'saved' : 'none');
}
render(); setInterval(render, 250);
</script>"""

VERIFY_WINDOW = ('import AppKit\nimport CoreGraphics\n'
                 'if CommandLine.arguments.count == 1 { exit((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true ? 2 : 0) }\n'
                 'let pid = Int32(CommandLine.arguments[1])!\nlet id = UInt32(CommandLine.arguments[2])!\n'
                 'let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []\n'
                 'guard entries.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowNumber as String] as? UInt32) == id }) else { exit(1) }\n')


class Fixture(BaseHTTPRequestHandler):
    counter = 0
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def reply(self, body, content_type='text/plain', cache='no-store'):
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', cache)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path == '/cookie-state':
            cookies = self.headers.get('Cookie', '')
            self.reply(b'connected' if 'session=connected' in cookies else b'disconnected')
        elif path == '/worker.js':
            self.reply(b"self.addEventListener('fetch', () => {});", 'text/javascript')
        elif path == '/status':
            self.reply(STATUS_PAGE, 'text/html')
        elif path == '/http-cached':
            with Fixture.lock:
                Fixture.counter += 1
                value = Fixture.counter
            self.reply(str(value).encode(), cache='max-age=3600')
        else:
            self.reply(b'<!doctype html><title>Synthetic site data</title><p>Loopback site data fixture</p>', 'text/html')


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app, root)
    lab.APP = args.app.resolve()
    (root / '.orbit-chromium-lab').write_text(lab.MARKER)
    directory = root / 'phase'
    if directory.exists():
        subprocess.run(['/bin/rm', '-rf', str(directory)], check=True)
    directory.mkdir(mode=0o700)
    (directory / '.orbit-chromium-lab').write_text(lab.MARKER)
    command = [str(args.app / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
               f'--orbit-data-root={root}/data', f'--orbit-smoke-run={directory}',
               f'--orbit-smoke-fixture=http://127.0.0.1:{args.port}/',
               '--orbit-smoke-phase=fresh', '--orbit-smoke-profile-site-data',
               '-AppleLanguages', '(en)', '-AppleLocale', 'en_US']
    with lab.OwnedProcessRun() as owner:
        with (directory / 'stdout.log').open('w') as out, (directory / 'stderr.log').open('w') as err:
            process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            process.wait(timeout=55)
    results = json.loads((directory / 'results.json').read_text())
    rows = {row['id']: row for row in results['results'] if row['id'].startswith('profile-site.')}
    print(json.dumps(rows, indent=2))
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    assert not results['aborted']
    proven = {name for name in REQUIRED if rows.get('profile-site.' + name, {}).get('status') == 'proven'}
    assert proven == REQUIRED, sorted(REQUIRED - proven)
    print(f'Profile site data: {len(REQUIRED)} checks, clean normal shutdown')


def clip_phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app, root)
    if subprocess.run([str(root / 'verify-window')], check=False).returncode != 0:
        raise RuntimeError('The GUI session is locked; no test bundle was launched')
    lab.APP = args.app.resolve()
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    for name in ['perf-state.json', 'site-data-window.txt', 'site-data-shot.txt']:
        (data / name).unlink(missing_ok=True)
    (root / 'clear-flow.mov').unlink(missing_ok=True)

    def expired(*_):
        raise TimeoutError('Site data GUI lease expired')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(55)
    started = time.monotonic()
    recording, checks = None, None
    with lab.OwnedProcessRun() as owner:
        with (root / 'clip-stdout.log').open('w') as out, (root / 'clip-stderr.log').open('w') as err:
            process = owner.launch([str(args.app / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--perf-probe',
                                    f'--orbit-data-root={data}', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'],
                                   stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 14
                while True:
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    try:
                        ready = json.loads(state.read_text())
                    except (OSError, ValueError):
                        ready = {}
                    if ready.get('interactiveUptime') and ready.get('windowNumber') and ready.get('pid') == process.pid:
                        break
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                window = int(ready['windowNumber'])
                subprocess.run([str(root / 'verify-window'), str(process.pid), str(window)], check=True)
                # PID-scoped Accessibility activation, after live window-owner validation.
                subprocess.run(['/usr/bin/osascript', '-e', 'tell application "System Events" to set frontmost of '
                                f'first application process whose unix id is {process.pid} to true'],
                               check=True, timeout=4, stdout=out, stderr=err)
                nonce = str(time.monotonic_ns())
                control.write_text(json.dumps({'command': 'site-data-clear', 'nonce': nonce,
                                               'url': f'http://127.0.0.1:{args.port}/'}))
                deadline = time.monotonic() + 38
                while time.monotonic() < deadline:
                    assert process.poll() is None
                    window_file, shot = data / 'site-data-window.txt', data / 'site-data-shot.txt'
                    if recording is None and window_file.exists():
                        settings = int(window_file.read_text())
                        subprocess.run([str(root / 'verify-window'), str(process.pid), str(settings)], check=True)
                        recording = subprocess.Popen(['/usr/sbin/screencapture', '-x', '-v', '-V', '12', '-l', str(settings),
                                                      str(root / 'clear-flow.mov')], stdout=out, stderr=err)
                    if shot.exists():
                        name, number = shot.read_text().split(':')
                        subprocess.run([str(root / 'verify-window'), str(process.pid), number], check=True)
                        subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', number, str(root / f'page-{name}.png')],
                                       check=True, stdout=out, stderr=err)
                        shot.unlink()
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'siteDataClear' in result:
                        checks = result['siteDataClear']
                        break
                    time.sleep(.05)
                else:
                    raise TimeoutError('Site data clear flow')
                if recording is not None:
                    assert recording.wait(timeout=12) == 0, 'Window recording failed'
            finally:
                if recording is not None and recording.poll() is None:
                    recording.terminate()
                    recording.wait(timeout=3)
                control.write_text('{"command":"quit"}')
                process.wait(timeout=5)
    signal.alarm(0)
    report = {'result': checks, 'guiSeconds': time.monotonic() - started,
              'cleanShutdown': process.returncode == 0 and not owner.remaining and not owner.forced_signals}
    (root / 'clip-verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    assert checks and checks.get('passed') and report['cleanShutdown'], report


def encode_clip(root):
    source = root / 'clear-flow.mov'
    if not source.exists():
        return
    clip, poster = root / 'site-data-clear.mp4', root / 'site-data-clear.jpg'
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(source), '-an', '-t', '15',
                    '-vf', "scale='min(1440,iw)':-2", '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '26',
                    '-preset', 'slow', '-movflags', '+faststart', str(clip)], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-ss', '6', '-i', str(clip), '-frames:v', '1',
                    '-q:v', '3', str(poster)], check=True)
    print(f'clip {clip} ({clip.stat().st_size} bytes), poster {poster}')


def cleanup_registration(app):
    import plistlib
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    identifier = info['CFBundleIdentifier']
    if info.get('OrbitSyntheticBundle') is True and identifier.startswith('lab.orbit.orbit.'):
        for command in [['/usr/bin/tccutil', 'reset', 'All', identifier], ['/usr/bin/defaults', 'delete', identifier],
                        ['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                         '-u', str(app)]]:
            subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Bundle must be baked with --synthetic-root <output>/data')
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    parser.add_argument('--clip', action='store_true', help='Visible Settings flow with a recorded clip')
    args = parser.parse_args()
    if args.phase:
        clip_phase(args) if args.clip else phase(args)
        return
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    if args.clip:
        helper = root / 'verify-window.swift'
        helper.write_text(VERIFY_WINDOW)
        subprocess.run(['/usr/bin/swiftc', str(helper), '-o', str(root / 'verify-window')], check=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
                        '--app', str(args.app.resolve()), '--output', str(root), '--phase',
                        '--port', str(server.server_port), *(['--clip'] if args.clip else [])], check=True)
        if args.clip:
            encode_clip(root)
    finally:
        server.shutdown()
        server.server_close()
        if args.clip:
            cleanup_registration(args.app.resolve())


if __name__ == '__main__':
    main()
