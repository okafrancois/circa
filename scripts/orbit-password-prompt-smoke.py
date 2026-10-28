#!/usr/bin/env python3
"""Record native password decisions and renderer autofill in a synthetic Chromium bundle.

Every GUI session uses the shared slot for at most 55 seconds. Credentials, server and profile
are invented; the stopped database is opened read-only. No personal Keychain access.
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
SPEC = importlib.util.spec_from_file_location('password_lab', REPO / 'scripts/orbit-chromium-lab.py')
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, login=False, filled=False):
        form = '''<section><h2>Fixture login</h2><form method="post" action="/submit">
<input id="username" name="username" autocomplete="username" aria-label="Username">
<input id="password" name="password" type="password" autocomplete="current-password" aria-label="Password">
<button>Sign in to fixture</button></form></section>''' if login else ''
        body = f'''<!doctype html><title>{'Fixture filled' if filled else 'Orbit Recording Fixture'}</title>
<style>body{{font:20px -apple-system,sans-serif;background:#f2efe6;color:#193034;margin:38px}}
h1{{font-size:44px}}h2{{font-size:30px}}section{{border:1px solid #9fadae;padding:20px;margin:20px 0}}
input,button{{font:20px -apple-system,sans-serif;padding:10px;margin:8px}}input{{width:218px}}
.tile{{width:160px;height:80px;background:#53a8ac}}.circle{{width:60px;height:60px;background:#f5d585;border-radius:50%;margin-left:50px;position:relative;top:10px}}</style>
<h1>Orbit Recording Fixture</h1><p>Neutral local content for browser reference capture.</p>
<nav><a href="/">Alpha</a> · <a href="/">Beta</a> · <a href="/login">Login</a> · <a href="/">Media</a> · <a href="/">Permission</a> · <a href="/">Download sample</a></nav>
<section><h2>Buttons and repeated tiles</h2><button>First button</button><button>Second button</button><button>Third button</button>
<div class="tile"><div class="circle"></div></div><p>Stable fixture paragraph.</p><button>Update page</button></section>
{form}<iframe title="Nested fixture" srcdoc="<h2>Nested fixture</h2><fieldset>Inner local frame<br><button>Inner button</button></fieldset>" width="1200" height="190"></iframe>'''
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self):
        self.reply(login=True)

    def do_POST(self):
        values = parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
        self.reply(filled=values == {'username': ['orbit-test'], 'password': ['FixtureOnly-942026']})


def phase(args):
    root = args.output.resolve()
    directory = root / 'phase'
    directory.mkdir()
    (directory / '.orbit-chromium-lab').write_text(lab.MARKER)
    command = [str(args.app / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
               f'--orbit-data-root={root}/data', f'--orbit-smoke-run={directory}',
               f'--orbit-smoke-fixture=http://127.0.0.1:{args.port}/',
               '--orbit-smoke-phase=fresh', '--orbit-smoke-password-prompt']
    with lab.OwnedProcessRun() as owner:
        with (directory / 'stdout.log').open('w') as out, (directory / 'stderr.log').open('w') as err:
            process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                process.wait(timeout=53)
            except subprocess.TimeoutExpired:
                pass
    results = json.loads((directory / 'results.json').read_text())
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    stores = []
    for path in (root / 'data/Chromium').glob('profile-*/Login Data'):
        with sqlite3.connect(f'file:{path}?mode=ro', uri=True) as connection:
            rows = connection.execute('select blacklisted_by_user,password_value from logins').fetchall()
        stores.extend({'blocked': bool(blocked), 'encrypted': password.startswith(b'v10') and b'FixtureOnly-' not in password}
                      for blocked, password in rows)
    verdict = {'results': results, 'stores': stores}
    (root / 'verification.json').write_text(json.dumps(verdict, indent=2) + '\n')
    print(json.dumps(verdict, indent=2))
    assert not results['aborted'] and all(r['status'] != 'failed' for r in results['results'])
    assert len(stores) == 2 and sum(s['blocked'] for s in stores) == 1
    assert all(s['encrypted'] for s in stores if not s['blocked'])


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
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/arcy-gui-slot.lock', 'python3', __file__,
                        '--app', str(args.app.resolve()), '--output', str(root), '--phase',
                        '--port', str(server.server_port)], check=True)
    finally:
        server.shutdown(); server.server_close(); worker.join()


if __name__ == '__main__':
    main()
