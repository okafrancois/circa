#!/usr/bin/env python3
"""Check built-in ad and tracker blocking in a synthetic product bundle on loopback fixtures.

Build the bundle with the test identifier lab.orbit.orbit.content-blocking, then:
  python3 scripts/orbit-content-blocking-smoke.py --app <bundle> --output /tmp/<run>
Then, on the same root, `--private` checks the private session and `--relaunch` a restart.
The fixture maps *.fixture.test sites and known ad and tracker hosts to a loopback server that
logs every request it receives. Each phase runs in one GUI lease of at most 55 s.
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
SPEC = importlib.util.spec_from_file_location('engine_security_fixture', REPO / 'scripts/orbit-engine-security-smoke.py')
security = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(security)
validation, lab = security.validation, security.lab

PAGE = """<!doctype html><meta charset=utf-8><title>pending</title>
<style>body{font:20px -apple-system,sans-serif;margin:28px;background:#fff;color:#111}
h1{font-size:26px}td{padding:7px 14px;border-bottom:1px solid #ddd}.loaded{background:#c9f2c4}.blocked{background:#f6c4c4}</style>
<h1>Content blocking fixture: <span id=site></span></h1><table id=results></table><p id=summary></p>
<script>
const P = location.port;
document.getElementById('site').textContent = location.hostname;
const tests = [
  ['EasyList: securepubads.g.doubleclick.net/tag/js/gpt.js', 'script', `http://securepubads.g.doubleclick.net:${P}/tag/js/gpt.js`],
  ['EasyPrivacy: b.scorecardresearch.com/beacon.js', 'script', `http://b.scorecardresearch.com:${P}/beacon.js`],
  ['EasyList: /ads/banners/top.gif', 'img', '/ads/banners/top.gif'],
  ['EasyPrivacy: /analytics/analytics.js', 'script', '/analytics/analytics.js'],
  ['Control: /static/app.js', 'script', '/static/app.js']];
const table = document.getElementById('results');
let done = 0, blocked = 0, control = false;
for (const [label, kind, url] of tests) {
  const row = table.insertRow(); row.insertCell().textContent = label;
  const cell = row.insertCell(); cell.textContent = '...';
  const element = document.createElement(kind);
  const finish = (ok) => {
    cell.textContent = ok ? 'LOADED' : 'BLOCKED'; row.className = ok ? 'loaded' : 'blocked';
    if (label.startsWith('Control')) control = ok; else if (!ok) blocked++;
    if (++done === tests.length) {
      document.title = `CB ${blocked}/4 blocked, control ${control ? 'loaded' : 'failed'}`;
      document.getElementById('summary').textContent = document.title;
    }
  };
  element.onload = () => finish(true); element.onerror = () => finish(false);
  element.src = url + '?t=' + Date.now(); document.body.appendChild(element);
}
</script>"""
GIF = bytes.fromhex('47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b')


class Fixture(BaseHTTPRequestHandler):
    log_path = None

    def do_GET(self):
        path = self.path.split('?')[0]
        with open(self.log_path, 'a') as log:
            log.write(json.dumps({'t': round(time.time(), 3), 'host': self.headers.get('Host', ''), 'path': path}) + '\n')
        if path == '/':
            body, kind = PAGE.encode(), 'text/html; charset=utf-8'
        elif path.endswith('.gif'):
            body, kind = GIF, 'image/gif'
        elif path.endswith('.js'):
            body, kind = b'window.fixtureLoaded = (window.fixtureLoaded || 0) + 1;', 'application/javascript'
        else:
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    lab.APP = args.app.resolve()
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    nonce = str(time.monotonic_ns())

    def timeout(*_):
        raise TimeoutError('55-second GUI lease')
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(55)
    started = time.monotonic()
    with lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--perf-probe',
                '--orbit-content-blocking-fixture', f'--orbit-data-root={data}'], stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 15
                while not state.exists():
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                command = {'command': 'content-blocking', 'nonce': nonce, 'port': str(args.port)}
                if args.relaunch:
                    command['step'] = 'relaunch'
                    time.sleep(4)  # The restored tab loads on its own first.
                elif args.private:
                    command['step'] = 'private'
                    time.sleep(2)
                temporary = data / 'perf-command.pending'
                temporary.write_text(json.dumps(command)); temporary.replace(control)
                deadline = time.monotonic() + 49
                while time.monotonic() < deadline:
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'contentBlocking' in result:
                        checks = result['contentBlocking']
                        break
                    time.sleep(.05)
                else:
                    raise TimeoutError('Content blocking probe')
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=20)
    signal.alarm(0)
    checks['guiSeconds'] = round(time.monotonic() - started, 2)
    checks['clean'] = process.returncode == 0 and not owner.remaining and not owner.forced_signals
    (root / verification_name(args)).write_text(json.dumps(checks, indent=2) + '\n')


def verification_name(args):
    return 'verification-relaunch.json' if args.relaunch else 'verification-private.json' if args.private else 'verification.json'


TRACKER_HOSTS = {'securepubads.g.doubleclick.net', 'b.scorecardresearch.com'}


def is_tracker(request):
    return request['host'].split(':')[0] in TRACKER_HOSTS or request['path'].startswith(('/ads/', '/analytics/'))


def summarize_private(root):
    """Tracker requests the server received per step; a private exception never reaches disk."""
    checks = json.loads((root / 'verification-private.json').read_text())
    requests = [json.loads(line) for line in (root / 'server-private.jsonl').read_text().splitlines()]
    marks = checks.get('marks', [])
    phases = {}
    for index, current in enumerate(marks[:-1]):
        start, end = current['t'], marks[index + 1]['t']
        phases[current['step']] = sum(1 for r in requests if start <= r['t'] < end and is_tracker(r))
    checks['serverTrackerRequestsPerStep'] = phases
    # Nothing of the private session is written below the data root (cookies, rules, preferences).
    leaked = []
    for path in (root / 'data').rglob('*'):
        try:
            if path.is_file() and not path.is_symlink() and b'private.fixture.test' in path.read_bytes():
                leaked.append(str(path.relative_to(root)))
        except OSError:
            pass
    checks['privateHostOnDisk'] = leaked
    (root / 'verification-private.json').write_text(json.dumps(checks, indent=2) + '\n')
    blocked, allowed = 'CB 4/4 blocked, control loaded', 'CB 0/4 blocked, control loaded'
    row = 'Ads & Trackers, %s'
    expected = {'parentExceptions': ['news.fixture.test'], 'privateNewsInherited': allowed,
                'privateNewsRow': row % 'Allowed', 'privateNewsRowEditable': False,
                'privateBlocked': blocked, 'privateRowBefore': row % 'Blocked', 'privateRowAfter': row % 'Allowed',
                'privateException': allowed, 'persistentExceptionsAfterPrivate': ['news.fixture.test'],
                'privateWindowsAfterClose': 0, 'privateNewSession': blocked, 'privateParentOff': allowed,
                'privateRowWhileParentOff': 'absent', 'privateParentOnAgain': blocked, 'privateHostOnDisk': [],
                'serverTrackerRequestsPerStep': {'privateNewsInherited': 4, 'privateBlocked': 0, 'privateException': 4,
                                                 'privateNewSession': 0, 'privateParentOff': 4, 'privateParentOnAgain': 0},
                'clean': True}
    failures = {key: checks.get(key) for key, value in expected.items() if checks.get(key) != value}
    print(json.dumps(checks, indent=2))
    assert not failures, failures
    print('Private content blocking passed; %.2f s GUI lease' % checks['guiSeconds'])


def summarize_relaunch(root):
    checks = json.loads((root / 'verification-relaunch.json').read_text())
    requests = [json.loads(line) for line in (root / 'server-relaunch.jsonl').read_text().splitlines()]
    checks['serverRequests'] = [r['host'].split(':')[0] + r['path'] for r in requests]
    (root / 'verification-relaunch.json').write_text(json.dumps(checks, indent=2) + '\n')
    print(json.dumps(checks, indent=2))
    trackers = [r for r in checks['serverRequests'] if 'doubleclick' in r or 'scorecardresearch' in r or '/ads/' in r or '/analytics/' in r]
    assert checks.get('restored') == 'CB 4/4 blocked, control loaded' and not trackers and checks.get('clean'), checks
    print('Relaunch passed: the restored tab was filtered from its first request')


def summarize(root):
    checks = json.loads((root / 'verification.json').read_text())
    requests = [json.loads(line) for line in (root / 'server.jsonl').read_text().splitlines()]
    checks['serverTrackerRequests'] = sorted({r['host'].split(':')[0] + r['path'] for r in requests if is_tracker(r)})
    (root / 'verification.json').write_text(json.dumps(checks, indent=2) + '\n')
    blocked, allowed = 'CB 4/4 blocked, control loaded', 'CB 0/4 blocked, control loaded'
    expected = {'available': True, 'defaultSetting': True, 'newsOn': blocked, 'internalExtensionListed': False,
                'newsAllowListed': allowed, 'shopStillBlocked': blocked, 'shopOff': allowed, 'siteRowWhileOff': 'absent',
                'shopOnAgain': blocked, 'privateBlockerAvailable': False, 'privateShop': blocked,
                'privateSiteRow': 'Ads & Trackers, Blocked', 'exceptions': ['news.fixture.test'], 'clean': True}
    failures = {key: checks.get(key) for key, value in expected.items() if checks.get(key) != value}
    print(json.dumps(checks, indent=2))
    assert not failures, failures
    print('Content blocking smoke passed; %.2f s GUI lease' % checks['guiSeconds'])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--relaunch', action='store_true', help='Reopen the data root of a passed run')
    group.add_argument('--private', action='store_true', help='Private session cases on the data root of a passed run')
    args = parser.parse_args()
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    if args.phase:
        phase(args)
        return
    if args.relaunch or args.private:
        assert (root / 'verification.json').exists(), 'Run the first phase on this root first'
        port = int((root / 'port.txt').read_text())
        (root / 'data/perf-state.json').unlink()
    else:
        assert not (root / 'data/perf-state.json').exists(), 'Use a fresh synthetic root'
        port = 0
    Fixture.log_path = root / ('server-relaunch.jsonl' if args.relaunch else 'server-private.jsonl' if args.private else 'server.jsonl')
    Fixture.log_path.write_text('')
    http = ThreadingHTTPServer(('127.0.0.1', port), Fixture)
    (root / 'port.txt').write_text(str(http.server_port))
    http.daemon_threads = True
    threading.Thread(target=http.serve_forever, daemon=True).start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__, '--app', str(args.app.resolve()),
            '--output', str(root), '--phase', '--port', str(http.server_port)]
            + (['--relaunch'] if args.relaunch else ['--private'] if args.private else []), check=True)
    finally:
        http.shutdown(); http.server_close()
    summarize_relaunch(root) if args.relaunch else summarize_private(root) if args.private else summarize(root)


if __name__ == '__main__':
    main()
