#!/usr/bin/env python3
"""Qualify that history deletions in Circa also leave the engine's own history.

Build the product app, then a synthetic bundle with the bundle id lab.orbit.orbit.history-engine-purge:
  python3 scripts/orbit-app.py build --synthetic --source-app <build>/product/Orbit.app \\
      --bundle-id lab.orbit.orbit.history-engine-purge --synthetic-root <output>/data --output <output>/Orbit.app
  python3 scripts/orbit-history-engine-purge-smoke.py --app <output>/Orbit.app --output <output>

Two launches, each in the GUI slot (window IDs verified against the bundle's PID, only those
windows recorded): the first visits loopback pages on two hosts and deletes one host, one visit
and a time interval through the Library, while a second window of the same process mirrors the
engine's own history page of the profile; the second deletes the last hour. After each clean
shutdown the engine's History database is read read-only. The clip shows the first launch.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('site_data_clear', REPO / 'scripts/orbit-site-data-clear-smoke.py')
site_data = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(site_data)
validation, lab = site_data.validation, site_data.lab

PAGE = """<!doctype html><meta charset=utf-8><title>Synthetic {name}</title>
<style>body{{font:20px -apple-system,sans-serif;margin:0;display:grid;place-items:center;height:100vh;background:#f4f4f6}}
.card{{background:#fff;border-radius:14px;padding:32px 48px;box-shadow:0 2px 12px #0001}}</style>
<div class=card><h1>Synthetic page “{name}”</h1><p>Loopback history fixture</p></div>"""


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        name = self.path.split('?', 1)[0].strip('/') or 'index'
        body = PAGE.format(name=name.capitalize()).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def engine_history(data):
    """URLs and visit count of every engine profile's History database, opened read-only."""
    rows = {}
    for database in sorted(data.glob('Chromium/profile-*/History')):
        connection = sqlite3.connect(f'file:{database}?mode=ro', uri=True)
        try:
            urls = [row[0] for row in connection.execute('SELECT url FROM urls ORDER BY id')]
            visits = connection.execute('SELECT COUNT(*) FROM visits').fetchone()[0]
        finally:
            connection.close()
        rows[database.parent.name] = {'urls': urls, 'visits': visits}
    return rows


def session(args, step, record):
    root = args.output.resolve()
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    for name in ['perf-state.json', 'history-windows.txt', 'history-stop.txt']:
        (data / name).unlink(missing_ok=True)
    recordings, checks = [], None
    started = time.monotonic()
    with lab.OwnedProcessRun() as owner:
        with (root / f'{step}-stdout.log').open('w') as out, (root / f'{step}-stderr.log').open('w') as err:
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
                control.write_text(json.dumps({'command': 'history-engine-purge', 'nonce': nonce, 'step': step,
                                               'url': f'http://127.0.0.1:{args.port}/'}))
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    assert process.poll() is None
                    windows = data / 'history-windows.txt'
                    if record and not recordings and windows.exists():
                        for index, number in enumerate(windows.read_text().split(':')):
                            subprocess.run([str(root / 'verify-window'), str(process.pid), number], check=True)
                            movie = root / f'window-{index}.mov'
                            movie.unlink(missing_ok=True)
                            recordings.append(subprocess.Popen(['/usr/sbin/screencapture', '-x', '-v', '-V', '16', '-l', number,
                                                                str(movie)], stdout=out, stderr=err))
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'historyEnginePurge' in result:
                        checks = result['historyEnginePurge']
                        break
                    time.sleep(.05)
                else:
                    raise TimeoutError('History deletion flow')
                for recording in recordings:
                    assert recording.wait(timeout=16) == 0, 'Window recording failed'
            finally:
                for recording in recordings:
                    if recording.poll() is None:
                        recording.terminate()
                        recording.wait(timeout=3)
                control.write_text('{"command":"quit"}')
                process.wait(timeout=8)
    return {'result': checks, 'guiSeconds': time.monotonic() - started,
            'cleanShutdown': process.returncode == 0 and not owner.remaining and not owner.forced_signals,
            'engineDatabase': engine_history(data)}


def expired(*_):
    raise TimeoutError('History GUI lease expired')


def phases(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app, root)
    if subprocess.run([str(root / 'verify-window')], check=False).returncode != 0:
        raise RuntimeError('The GUI session is locked; no test bundle was launched')
    lab.APP = args.app.resolve()

    signal.signal(signal.SIGALRM, expired)
    signal.alarm(58)
    report = {'partial': session(args, 'partial', record=True)}
    signal.alarm(0)
    (root / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return report


def period_phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app, root)
    lab.APP = args.app.resolve()
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(58)
    report = session(args, 'period', record=False)
    signal.alarm(0)
    print(json.dumps(report, indent=2))
    return report


def check(report):
    partial, period = report['partial'], report['period']
    names = lambda urls: sorted(url.rstrip('/').rsplit('/', 1)[-1] for url in urls)
    partial_db = [entry for entry in partial['engineDatabase'].values() if entry['urls']]
    period_db = list(period['engineDatabase'].values())
    assert partial['cleanShutdown'] and period['cleanShutdown'], 'unclean shutdown'
    assert partial['result'] and partial['result'].get('passed'), partial['result']
    assert period['result'] and period['result'].get('passed'), period['result']
    # After the first launch only the kept page is in the engine's database; nothing after the last hour.
    assert len(partial_db) == 1 and names(partial_db[0]['urls']) == ['alpha'], partial['engineDatabase']
    assert all(not entry['urls'] and entry['visits'] == 0 for entry in period_db), period['engineDatabase']


def encode_clip(root):
    sources = [root / 'window-0.mov', root / 'window-1.mov']
    if not all(source.exists() for source in sources):
        return
    clip, poster = root / 'history-engine-purge.mp4', root / 'history-engine-purge.jpg'
    graph = ('[0:v]scale=-2:720,setsar=1[a];[1:v]scale=-2:720,setsar=1[b];[a][b]hstack=inputs=2,'
             "scale='min(1440,iw)':-2,pad=ceil(iw/2)*2:ceil(ih/2)*2[v]")
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(sources[0]), '-i', str(sources[1]),
                    '-filter_complex', graph, '-map', '[v]', '-an', '-t', '15', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
                    '-crf', '27', '-preset', 'slow', '-movflags', '+faststart', str(clip)], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-ss', '13', '-i', str(clip), '-frames:v', '1',
                    '-q:v', '3', str(poster)], check=True)
    for source in sources:
        source.unlink()
    print(f'clip {clip} ({clip.stat().st_size} bytes), poster {poster}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Bundle must be baked with --synthetic-root <output>/data')
    parser.add_argument('--phase', choices=['partial', 'period'])
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    root = args.output.resolve()
    if args.phase:
        report = phases(args) if args.phase == 'partial' else {'period': period_phase(args)}
        (root / f'{args.phase}.json').write_text(json.dumps(report, indent=2) + '\n')
        return
    validation.validate_bundle(args.app.resolve(), root)
    helper = root / 'verify-window.swift'
    helper.write_text(site_data.VERIFY_WINDOW)
    subprocess.run(['/usr/bin/swiftc', str(helper), '-o', str(root / 'verify-window')], check=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for phase in ['partial', 'period']:
            subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
                            '--app', str(args.app.resolve()), '--output', str(root), '--phase', phase,
                            '--port', str(server.server_port)], check=True)
        report = {'partial': json.loads((root / 'partial.json').read_text())['partial'],
                  'period': json.loads((root / 'period.json').read_text())['period']}
        (root / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
        check(report)
        encode_clip(root)
        print('History engine purge: partial deletions and last hour verified in the engine history')
    finally:
        server.shutdown()
        server.server_close()
        site_data.cleanup_registration(args.app.resolve())


if __name__ == '__main__':
    main()
