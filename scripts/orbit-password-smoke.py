#!/usr/bin/env python3
"""Hosted password WebUI/renderer probe with synthetic profiles and mock Keychain only.

Build the shell and package its smoke variant with orbit-app.py build --synthetic first.
Each app run holds the shared GUI slot for at most 55 seconds. OS authentication is mocked
in the smoke-only Swift scenario; no personal credentials, profiles or services are used.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

REPO = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("password_lab", REPO / "scripts/orbit-chromium-lab.py")
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self):
        self.reply('''<!doctype html><title>Fixture login</title>
<style>input,button { display:block; margin:15px; width:220px; height:30px; }</style>
<form method="post" action="/login"><input name="username" autocomplete="username">
<input name="password" type="password" autocomplete="current-password">
<button id="submit">Log in</button></form>''')

    def do_POST(self):
        values = parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
        filled = values == {"username": ["orbit-fixture-user"], "password": ["orbit-fixture-secret"]}
        self.reply('<title>Fixture filled</title>' if filled else '<title>Fixture empty</title>')


def phase(args):
    root = args.output.resolve()
    directory = root / 'phase'
    directory.mkdir()
    (directory / '.orbit-chromium-lab').write_text(lab.MARKER)
    command = [str(args.app / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
               f'--orbit-data-root={root}/data', f'--orbit-smoke-run={directory}',
               f'--orbit-smoke-fixture=http://127.0.0.1:{args.port}/',
               '--orbit-smoke-phase=fresh', '--orbit-smoke-passwords']
    with lab.OwnedProcessRun() as owner:
        with (directory / 'stdout.log').open('w') as out, (directory / 'stderr.log').open('w') as err:
            process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                process.wait(timeout=50)
            except subprocess.TimeoutExpired:
                pass
    results = json.loads((directory / 'results.json').read_text())
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    # Inspect only stopped synthetic databases, never mutate the engine's live SQLite store.
    stores = []
    for path in (root / 'data/Chromium').glob('profile-*/Login Data'):
        with sqlite3.connect(f'file:{path}?mode=ro', uri=True) as connection:
            rows = connection.execute('select password_value from logins').fetchall()
        stores.append({'credentials': len(rows), 'encrypted': bool(rows) and all(
            row[0] and b'orbit-fixture-secret' not in row[0] for row in rows)})
    (root / 'store-check.json').write_text(json.dumps(stores, indent=2) + '\n')
    print(json.dumps({'results': results, 'stores': stores}, indent=2))
    assert sum(s['credentials'] for s in stores) == 2 and all(s['encrypted'] for s in stores)
    assert not results['aborted'] and all(r['status'] != 'failed' for r in results['results'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    if args.phase:
        phase(args)
        return
    root = args.output.resolve()
    root.mkdir(mode=0o700)
    (root / '.orbit-chromium-lab').write_text(lab.MARKER)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    assert server.server_port not in (4317, 4318, 4330)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/arcy-gui-slot.lock', 'python3', __file__,
                        '--app', str(args.app.resolve()), '--output', str(root), '--phase',
                        '--port', str(server.server_port)], check=True)
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


if __name__ == '__main__':
    main()
