#!/usr/bin/env python3
"""Signed loopback update qualification. Builds must already exist; never uses the real feed/key.

Every feed is signed with the test key (sign_update embeds the feed signature). The signed-*
cases cover the transition from a build without SURequireSignedFeed, acceptance of the next
signed feed by a build that requires it, and rejection of a tampered or unsigned feed.

The auth-transition case (with --previous-app) signs two synthetic profiles in to a loopback
authentication fixture with the previous engine, then checks that real Chromium requests stay
authenticated after a normal restart, the signed update to the new engine, a new login, another
restart and the next update. The fixture judges the persistent, session and HttpOnly cookies
it receives; isolated profiles must never present each other's tokens. --auth-expect lost
documents an engine that drops them instead.

Each GUI case owns the shared slot for at most 55 seconds. All archives, keys, bundles,
preferences and synthetic data are removed. Only fixed events and result summaries survive.
"""
import argparse
import base64
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit
import uuid

from local_signing import sign_chromium_bundle

ROOT = Path(__file__).resolve().parents[1]
TEST_ID = 'io.github.okatech.orbit.test.update'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def run(*args, **kw):
    return subprocess.run(list(map(str, args)), check=True, **kw)


def copy(source, destination):
    run('/bin/cp', '-cR', source, destination)


def clean_preferences():
    subprocess.run(['defaults', 'delete', TEST_ID], capture_output=True)
    cache = Path.home() / 'Library/Caches' / TEST_ID
    if cache.is_dir():
        def ignore_disappeared(function, path, error):
            if not isinstance(error[1], FileNotFoundError):
                raise error[1]
        shutil.rmtree(cache, onerror=ignore_disappeared)


SIGNED_NEXT_CASES = ('signed-next', 'signed-tampered', 'signed-unsigned')


def case_versions(name):
    return ('2', '3') if name in SIGNED_NEXT_CASES else ('1', '2')


def case(work, name, evidence):
    """Invoked only under lockf by main; commands are consumed inside the PID-checked app."""
    deadline = time.monotonic() + 52
    old_version, new_version = case_versions(name)
    valid = work / ('valid-%s.xml' % new_version)
    root, app = work / 'data', work / 'installed/Orbit.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    feed = urlsplit(info.get('SUFeedURL', ''))
    if not (info.get('CFBundleIdentifier') == TEST_ID and info.get('OrbitUpdaterLocalTest') is True
            and info.get('OrbitSyntheticBundle') is True and info.get('OrbitUseMockKeychain') is True
            and Path(info.get('OrbitDataRoot', '')).resolve() == root.resolve()
            and feed.scheme == 'http' and feed.hostname == '127.0.0.1' and feed.port is not None
            and feed.username is None and feed.password is None
            and json.loads((root / '.orbit-synthetic-root').read_text())['bundleID'] == TEST_ID):
        raise RuntimeError('Refusing an unconfined update fixture')
    log = work / ('run-' + name + '.log')
    processes, seen = [], []
    checks = {}

    def archive_requests():
        path = work / 'requests.log'
        return path.read_text().count('archive\n') if path.exists() else 0

    def state():
        try:
            result = json.loads((root / 'perf-state.json').read_text())
            if result['pid'] not in seen:
                # A replacement PID is accepted only for our exact bundle executable.
                command = subprocess.check_output(['ps', '-p', str(result['pid']), '-o', 'comm='], text=True).strip()
                if Path(command).resolve() != (app / 'Contents/MacOS/Orbit').resolve():
                    return {}
                seen.append(result['pid'])
            return result
        except (OSError, ValueError, KeyError):
            return {}

    def wait(predicate, label):
        while time.monotonic() < deadline:
            for proc in processes:
                if proc.poll() is not None and proc.returncode < 0:
                    raise RuntimeError('Crash: stop all GUI qualification')
            value = state()
            if predicate(value):
                return value
            time.sleep(.05)
        raise RuntimeError('Deadline: ' + label)

    def command(action, **fields):
        # Probe ownsWindow verifies CGWindowList owner PID before every button event.
        nonce = str(time.monotonic_ns())
        payload = dict(command='update-test', action=action, nonce=nonce, **fields)
        tmp = root / 'command.tmp'
        tmp.write_text(json.dumps(payload))
        tmp.replace(root / 'perf-command.json')
        return nonce

    def launch(handle):
        (root / 'perf-state.json').unlink(missing_ok=True)
        proc = subprocess.Popen([str(app / 'Contents/MacOS/Orbit')], stdout=handle, stderr=handle)
        processes.append(proc)
        return wait(lambda s: bool(s.get('update')), 'launch')

    def quit_app():
        pid = state()['pid']
        (root / 'perf-command.json').write_text(json.dumps({'command': 'quit'}))
        wait(lambda _: subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode != 0, 'quit')

    try:
        clean_preferences()
        if name == 'off':
            run('defaults', 'write', TEST_ID, 'SUAutomaticallyUpdate', '-bool', 'false')
        with log.open('w') as handle:
            initial = launch(handle)
            seed_nonce = command('seed')
            seed_sent = time.monotonic()

            def seeded(value):
                nonlocal seed_nonce, seed_sent
                if 'about:blank#update-session' in value.get('update', {}).get('tabs', []):
                    return True
                # Startup can publish state before CGWindowList contains the owned window.
                # Retry only an acknowledged command after a fresh state publication;
                # the in-app probe still checks window ownership before every action.
                if value.get('commandNonce') == seed_nonce and time.monotonic() - seed_sent > 1:
                    seed_nonce = command('seed')
                    seed_sent = time.monotonic()
                return False

            wait(seeded, 'seed')
            if name == 'manual':
                shutil.copyfile(valid, work / 'feed/appcast.xml')
                time.sleep(.5)  # Let Sparkle finish scheduling after the previous cycle.
                command('check')
            if name in ('broken', 'signed-tampered', 'signed-unsigned'):
                wait(lambda _: 'aborted-code-' in log.read_text(), 'signature rejection')
                checks[name.replace('-', '_') + '_has_no_card'] = not state()['update']['card']
                checks['rejected_before_archive_download'] = name == 'broken' or archive_requests() == 0
                shutil.copyfile(valid, work / 'feed/appcast.xml')
                time.sleep(.5)  # Let Sparkle finish scheduling after the previous cycle.
                command('check')
            ready = wait(lambda s: s.get('update', {}).get('card') is True, 'prepared card')
            requests_before_click = archive_requests()
            checks['extracted_before_card'] = 'event=extracting ' in log.read_text()
            checks['staged_before_card'] = (ready['update']['pending'] == new_version
                                            and ready['update']['version'] == old_version)
            checks['no_standard_windows'] = not any('SU' in c or 'SPU' in c for c in ready['update']['windowClasses'])
            before = ready['update']['tabs']
            if name in ('off', 'toggle-off'):
                if name == 'toggle-off':
                    command('off')
                    ready = wait(lambda s: s.get('update', {}).get('automatic') is False, 'disable staged installation')
                checks['off_preference'] = ready['update']['automatic'] is False
                quit_app()
                checks['off_quit_preserves_old'] = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] == old_version
                launch(handle)
                wait(lambda s: s.get('update', {}).get('card') is True, 'restaged card')
            requests_before_click = archive_requests()
            if name == 'quit':
                quit_app()
                wait(lambda _: plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] == new_version, 'install on quit')
                after = launch(handle)
            else:
                pid = state()['pid']
                command('click')
                after = wait(lambda s: s.get('pid') != pid and s.get('update', {}).get('version') == new_version, 'relaunch')
            checks['no_download_on_click_or_quit'] = archive_requests() == requests_before_click
            checks['new_version'] = after['update']['version'] == new_version
            installed_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            checks['installed_requires_signed_feed'] = installed_info.get('SURequireSignedFeed') is True
            checks['session_restored'] = after['update']['tabs'] == before
            checks['no_standard_windows_after'] = not any('SU' in c or 'SPU' in c for c in after['update']['windowClasses'])
            quit_app()
        if not all(checks.values()):
            raise AssertionError(checks)
        events = [line for line in log.read_text().splitlines() if line.startswith('orbit-updater event=')]
        (evidence / (name + '-events.log')).write_text('\n'.join(events) + '\n')
        (evidence / (name + '.json')).write_text(json.dumps(checks, indent=2) + '\n')
        print(json.dumps({'case': name, 'checks': checks}), flush=True)
    finally:
        if log.exists():
            events = [line for line in log.read_text().splitlines() if line.startswith('orbit-updater event=')]
            (evidence / (name + '-events.log')).write_text('\n'.join(events) + '\n')
            (evidence / (name + '-last-state.json')).write_text(json.dumps(state(), indent=2) + '\n')
        # Normal termination first, then kill only a verified owned executable on timeout.
        for pid in set(seen + [proc.pid for proc in processes]):
            command_line = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip()
            if command_line and Path(command_line).resolve() == (app / 'Contents/MacOS/Orbit').resolve():
                (root / 'perf-command.json').write_text(json.dumps({'command': 'quit'}))
                for _ in range(10):
                    if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode != 0:
                        break
                    time.sleep(.1)
                else:
                    os.kill(pid, 9)
        for proc in processes:
            if proc.poll() is not None and proc.returncode < 0:
                (evidence / 'STOP-CRASH').write_text('Synthetic process exited by signal. No more GUI runs.\n')
        subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True)
        subprocess.run(['tccutil', 'reset', 'All', TEST_ID], capture_output=True)
        clean_preferences()


AUTH_COOKIES = ('auth', 'pref', 'sid', 'auth2')
AUTH_PERSISTENT = ('auth', 'pref')
AUTH_HTTP_ONLY = ('auth', 'sid', 'auth2')
AUTH_STAGES = ('auth-old', 'auth-update', 'auth-restart', 'auth-next')


def auth_server(work):
    """Loopback fixture: /login and /login2 set the cookies, /whoami reports what it received.
    Only statuses are logged (ok, foreign, stale, missing), never cookie values."""
    tokens = {label: {name: secrets.token_hex(12) for name in AUTH_COOKIES} for label in ('A', 'B')}
    log = work / 'auth.log'

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def do_GET(self):
            url = urlsplit(self.path)
            query = dict(item.split('=', 1) for item in url.query.split('&') if '=' in item)
            label, phase = query.get('profile', ''), query.get('phase', '')
            if label not in tokens or url.path not in ('/login', '/login2', '/whoami'):
                self.send_error(404)
                return
            received = {}
            for part in (self.headers.get('Cookie') or '').split(';'):
                if '=' in part:
                    name, value = part.strip().split('=', 1)
                    received.setdefault(name, []).append(value)
            statuses = {}
            for name in AUTH_COOKIES:
                values = received.get(name, [])
                if not values:
                    statuses[name] = 'missing'
                elif any(value == tokens[other][name] for other in tokens if other != label for value in values):
                    statuses[name] = 'foreign'
                elif values == [tokens[label][name]]:
                    statuses[name] = 'ok'
                else:
                    statuses[name] = 'stale'
            with log.open('a') as handle:
                handle.write(json.dumps({'path': url.path, 'profile': label, 'phase': phase, 'cookies': statuses}) + '\n')
            body = ('%s %s' % (label, ' '.join('%s=%s' % item for item in statuses.items()))).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            attributes = '; Path=/; SameSite=Lax'
            year = '; Max-Age=31536000'
            if url.path == '/login':
                self.send_header('Set-Cookie', 'auth=' + tokens[label]['auth'] + year + attributes + '; HttpOnly')
                self.send_header('Set-Cookie', 'pref=' + tokens[label]['pref'] + year + attributes)
                self.send_header('Set-Cookie', 'sid=' + tokens[label]['sid'] + attributes + '; HttpOnly')
            if url.path == '/login2':
                self.send_header('Set-Cookie', 'auth2=' + tokens[label]['auth2'] + year + attributes + '; HttpOnly')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return ThreadingHTTPServer(('127.0.0.1', 0), Handler)


def cookie_store_summary(root):
    """Synthetic profiles only, after the app quit: rows per encryption prefix, no values."""
    summary = {}
    engine = root / 'Chromium'
    for database in sorted([*engine.glob('*/Cookies'), *engine.glob('*/Network/Cookies')]):
        with tempfile.TemporaryDirectory(prefix='cookie-summary-') as temp:
            for sidecar in ('', '-wal', '-journal'):
                source = Path(str(database) + sidecar)
                if source.exists():
                    shutil.copyfile(source, Path(temp) / ('Cookies' + sidecar))
            connection = sqlite3.connect(Path(temp) / 'Cookies')
            rows = connection.execute("SELECT name, substr(encrypted_value, 1, 3), length(value) > 0, is_persistent "
                                      "FROM cookies WHERE host_key = '127.0.0.1'").fetchall()
            connection.close()
        counts = {}
        for name, prefix, plain, persistent in rows:
            kind = 'plain' if plain else prefix.decode(errors='replace') if isinstance(prefix, bytes) else str(prefix)
            counts.setdefault(name, []).append(kind + ('' if persistent else '-session'))
        summary[str(database.parent.relative_to(engine))] = {name: sorted(kinds) for name, kinds in sorted(counts.items())}
    return summary


def auth_stage(work, stage, evidence, expect):
    """One GUI session under lockf (at most 55 s including quit); see main for the sequence."""
    deadline = time.monotonic() + 52
    root, app = work / 'data', work / 'installed/Orbit.app'
    fixture = json.loads((work / 'auth-fixture.json').read_text())
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    feed = urlsplit(info.get('SUFeedURL', ''))
    if not (info.get('CFBundleIdentifier') == TEST_ID and info.get('OrbitUpdaterLocalTest') is True
            and info.get('OrbitSyntheticBundle') is True and info.get('OrbitUseMockKeychain') is True
            and Path(info.get('OrbitDataRoot', '')).resolve() == root.resolve()
            and feed.scheme == 'http' and feed.hostname == '127.0.0.1'
            and urlsplit(fixture['base']).hostname == '127.0.0.1'
            and json.loads((root / '.orbit-synthetic-root').read_text())['bundleID'] == TEST_ID):
        raise RuntimeError('Refusing an unconfined authentication fixture')
    log = work / ('run-' + stage + '.log')
    processes, seen, results = [], [], json.loads((work / 'auth-results.json').read_text())
    started, timeline = time.monotonic(), results.setdefault('timeline', {}).setdefault(stage, [])

    def mark(label):
        timeline.append('%.1f %s' % (time.monotonic() - started, label))

    def state():
        try:
            result = json.loads((root / 'perf-state.json').read_text())
            if result['pid'] not in seen:
                command = subprocess.check_output(['ps', '-p', str(result['pid']), '-o', 'comm='], text=True).strip()
                if Path(command).resolve() != (app / 'Contents/MacOS/Orbit').resolve():
                    return {}
                seen.append(result['pid'])
            return result
        except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
            return {}

    def wait(predicate, label):
        while time.monotonic() < deadline:
            for proc in processes:
                if proc.poll() is not None and proc.returncode < 0:
                    raise RuntimeError('Crash: stop all GUI qualification')
            value = state()
            if predicate(value):
                return value
            time.sleep(.05)
        mark('deadline ' + label)
        raise RuntimeError('Deadline: %s (%s)' % (label, stage))

    def command(action, **fields):
        # The in-app probe checks window ownership (CGWindowList owner PID) before any action.
        nonce = str(time.monotonic_ns())
        tmp = root / 'command.tmp'
        tmp.write_text(json.dumps(dict(command='update-test', action=action, nonce=nonce, **fields)))
        tmp.replace(root / 'perf-command.json')
        return nonce

    def launch(handle):
        (root / 'perf-state.json').unlink(missing_ok=True)
        processes.append(subprocess.Popen([str(app / 'Contents/MacOS/Orbit')], stdout=handle, stderr=handle))
        wait(lambda s: bool(s.get('update')), 'launch')
        nonce, sent = command('seed'), time.monotonic()

        def seeded(value):
            nonlocal nonce, sent
            if 'about:blank#update-session' in value.get('update', {}).get('tabs', []):
                return True
            if value.get('commandNonce') == nonce and time.monotonic() - sent > 1:
                nonce, sent = command('seed'), time.monotonic()
            return False
        value = wait(seeded, 'seed')
        mark('launched')
        return value

    def quit_app():
        pid = state()['pid']
        (root / 'perf-command.json').write_text(json.dumps({'command': 'quit'}))
        wait(lambda _: subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode != 0, 'quit')

    def authenticate(phase, steps):
        mark('auth ' + phase)
        fields = dict(base=fixture['base'], phase=phase, steps=steps, second=fixture['second'])
        nonce, sent = command('auth', **fields), time.monotonic()

        def answered(value):
            nonlocal nonce, sent
            if value.get('auth', {}).get('phase') == phase:
                return True
            # As for seed: a command consumed before CGWindowList lists the owned window is
            # ignored by the ownership check; resend only an acknowledged, unanswered command.
            if value.get('commandNonce') == nonce and time.monotonic() - sent > 1:
                nonce, sent = command('auth', **fields), time.monotonic()
            return False
        report = wait(answered, 'auth ' + phase)['auth']
        seen_by_fixture = {}
        for line in (work / 'auth.log').read_text().splitlines():
            entry = json.loads(line)
            if entry['phase'] == phase and entry['path'] == '/whoami':
                seen_by_fixture[entry['profile']] = entry['cookies']
        page = {label: report.get(label, {}).get('whoami', '') for label in ('A', 'B')}
        results['phases'][phase] = {'fixture': seen_by_fixture, 'page': page, 'version': state()['update']['version']}
        return seen_by_fixture, page

    def update(handle):
        before = wait(lambda s: s.get('update', {}).get('card') is True, 'prepared card')
        mark('card')
        pid = before['pid']
        command('click')
        after = wait(lambda s: s.get('pid') != pid and s.get('update', {}).get('version') == case_versions_auth(stage), 'relaunch')
        mark('relaunched')
        results['checks'][stage + '_session_restored'] = after['update']['tabs'] == before['update']['tabs']

    try:
        clean_preferences()
        with log.open('w') as handle:
            launch(handle)
            if stage == 'auth-old':
                authenticate('login', 'login,whoami')
                quit_app()
                launch(handle)
                authenticate('old-restart', 'whoami')
            elif stage == 'auth-update':
                update(handle)
                authenticate('updated', 'whoami')
                if expect == 'kept':
                    authenticate('new-login', 'login2,whoami')
            elif stage == 'auth-restart':
                authenticate('new-restart', 'whoami')
            elif stage == 'auth-next':
                update(handle)
                authenticate('next-update', 'whoami')
            quit_app()
        results['stores'][stage] = cookie_store_summary(root)
    finally:
        mark('end')
        (work / 'auth-results.json').write_text(json.dumps(results, indent=2) + '\n')
        if log.exists():
            events = [line for line in log.read_text().splitlines() if line.startswith('orbit-updater event=')]
            (evidence / (stage + '-events.log')).write_text('\n'.join(events) + '\n')
        last = state()
        (evidence / (stage + '-last-state.json')).write_text(json.dumps(
            {key: last.get(key) for key in ('pid', 'update', 'auth', 'commandNonce')}, indent=2) + '\n')
        for pid in set(seen + [proc.pid for proc in processes]):
            command_line = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip()
            if command_line and Path(command_line).resolve() == (app / 'Contents/MacOS/Orbit').resolve():
                (root / 'perf-command.json').write_text(json.dumps({'command': 'quit'}))
                for _ in range(10):
                    if subprocess.run(['kill', '-0', str(pid)], capture_output=True).returncode != 0:
                        break
                    time.sleep(.1)
                else:
                    os.kill(pid, 9)
        for proc in processes:
            if proc.poll() is not None and proc.returncode < 0:
                (evidence / 'STOP-CRASH').write_text('Synthetic process exited by signal. No more GUI runs.\n')
        subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True)
        subprocess.run(['tccutil', 'reset', 'All', TEST_ID], capture_output=True)
        clean_preferences()


def case_versions_auth(stage):
    return {'auth-update': '2', 'auth-next': '3'}[stage]


def auth_checks(results, expect):
    """Assertions over the fixture's view; the page view proves HttpOnly cookies stay hidden."""
    phases, checks = results['phases'], results['checks']

    def statuses(phase, label):
        return phases.get(phase, {}).get('fixture', {}).get(label, {})

    def has(phase, names):
        return all(all(statuses(phase, label).get(name) == 'ok' for name in names) for label in ('A', 'B'))

    every = [statuses(phase, label) for phase in phases for label in ('A', 'B')]
    checks['profiles_isolated'] = bool(every) and not any('foreign' in s.values() for s in every)
    checks['login_sets_persistent_session_and_httponly'] = has('login', ('auth', 'pref', 'sid'))
    def page_cookies(phase, label):
        page = phases[phase]['page'].get(label, '')
        return set(page.rsplit(' js=', 1)[1].split(',')) if ' js=' in page else set()

    checks['httponly_hidden_from_page'] = all(
        not page_cookies(phase, label) & set(AUTH_HTTP_ONLY)
        and (statuses(phase, label).get('pref') != 'ok' or 'pref' in page_cookies(phase, label))
        for phase in phases for label in ('A', 'B'))
    checks['old_engine_restart_keeps_persistent'] = has('old-restart', AUTH_PERSISTENT)
    baseline_session = [statuses('old-restart', label).get('sid') for label in ('A', 'B')]
    results['session_cookie_after_restart'] = baseline_session
    if expect == 'lost':
        checks['update_lost_authentication'] = all(statuses('updated', label).get(name) == 'missing'
                                                    for label in ('A', 'B') for name in AUTH_PERSISTENT)
        return checks
    checks['update_keeps_persistent'] = has('updated', AUTH_PERSISTENT)
    checks['update_session_cookie_like_restart'] = [statuses('updated', label).get('sid') for label in ('A', 'B')] == baseline_session
    checks['new_login_after_update'] = has('new-login', ('auth', 'pref', 'sid', 'auth2'))
    checks['restart_keeps_old_and_new'] = has('new-restart', ('auth', 'pref', 'auth2'))
    checks['next_update_keeps_old_and_new'] = has('next-update', ('auth', 'pref', 'auth2'))
    return checks


def run_auth_transition(work, root, evidence, expect, previous, builds, feed, empty, packaging):
    installed = work / 'installed/Orbit.app'
    if installed.exists():
        shutil.rmtree(installed)
    if root.exists():
        shutil.rmtree(root)
    packaging.prepare_synthetic_root(root, TEST_ID)
    copy(previous, installed)
    (work / 'auth.log').write_text('')
    (work / 'auth-results.json').write_text(json.dumps({'phases': {}, 'checks': {}, 'stores': {}}))
    stages = AUTH_STAGES if expect == 'kept' else AUTH_STAGES[:2]
    for stage in stages:
        if (evidence / 'STOP-CRASH').exists():
            raise RuntimeError('Crash: stop all GUI qualification')
        content = {'auth-old': empty, 'auth-update': (work / 'valid-2.xml').read_bytes(),
                   'auth-restart': empty, 'auth-next': (work / 'valid-3.xml').read_bytes()}[stage]
        (feed / 'appcast.xml').write_bytes(content)
        try:
            run('/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__, '--auth-stage', stage,
                '--work', work, '--evidence', evidence, '--auth-expect', expect)
        finally:
            results = json.loads((work / 'auth-results.json').read_text())
            (evidence / ('auth-transition-%s.json' % expect)).write_text(json.dumps(results, indent=2) + '\n')
    results = json.loads((work / 'auth-results.json').read_text())
    checks = auth_checks(results, expect)
    (evidence / ('auth-transition-%s.json' % expect)).write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps({'case': 'auth-transition', 'expect': expect, 'checks': checks}), flush=True)
    if not all(checks.values()):
        raise AssertionError(checks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-app', type=Path, default=ROOT / 'native/OrbitChromium/build/app-orbit-engine-extensions-r13/product/Orbit.app')
    parser.add_argument('--previous-app', type=Path, help='Previous engine product for engine-transition only; never launched directly')
    parser.add_argument('--evidence', type=Path, default=Path('/tmp/update-ux'))
    parser.add_argument('--case')
    names = ['background', 'manual', 'quit', 'off', 'toggle-off', 'broken',
             'signed-transition', *SIGNED_NEXT_CASES]
    parser.add_argument('--cases', nargs='+', default=names, choices=names + ['engine-transition', 'auth-transition'])
    parser.add_argument('--auth-expect', choices=('kept', 'lost'), default='kept',
                        help='auth-transition: the new engine keeps (default) or drops existing authentication')
    parser.add_argument('--auth-stage', choices=AUTH_STAGES)
    parser.add_argument('--work', type=Path)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    if args.case:
        case(args.work, args.case, args.evidence)
        return
    if args.auth_stage:
        auth_stage(args.work, args.auth_stage, args.evidence, args.auth_expect)
        return
    transitions = [name for name in ('engine-transition', 'auth-transition') if name in args.cases]
    if transitions and args.previous_app is None:
        parser.error('%s requires --previous-app' % transitions[0])
    if (args.evidence / 'STOP-CRASH').exists():
        raise RuntimeError('Previous crash: GUI qualification stopped')
    with tempfile.TemporaryDirectory(prefix='update-ux-') as temp:
        work = Path(temp).resolve()
        root = work / 'data'
        feed = work / 'feed'
        feed.mkdir()
        class Handler(SimpleHTTPRequestHandler):
            def log_message(self, *unused):
                pass

            def do_GET(self):
                with (work / 'requests.log').open('a') as handle:
                    handle.write('archive\n' if self.path.endswith('.zip') else 'feed\n')
                super().do_GET()
        server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=feed))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        authentication = auth_server(work)
        threading.Thread(target=authentication.serve_forever, daemon=True).start()
        (work / 'auth-fixture.json').write_text(json.dumps({
            'base': 'http://127.0.0.1:%d' % authentication.server_port, 'second': str(uuid.uuid4()).upper()}))
        try:
            spec = importlib.util.spec_from_file_location('orbit_app', ROOT / 'scripts/orbit-app.py')
            packaging = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(packaging)
            base = work / 'base/Orbit.app'
            run(sys.executable, ROOT / 'scripts/orbit-app.py', 'build', '--synthetic', '--source-app', args.source_app,
                '--output', base, '--synthetic-root', root, '--bundle-id', 'lab.orbit.orbit.update-ux', stdout=subprocess.DEVNULL)
            # CryptoKit generates a test-only key directly to files; never touches Keychain.
            key, public = work / 'key', work / 'public'
            run('xcrun', 'swift', '-e', '''import Foundation; import CryptoKit
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
try key.publicKey.rawRepresentation.base64EncodedData().write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
''', key, public)
            key.chmod(0o600)
            infofile = base / 'Contents/Info.plist'
            info = plistlib.loads(infofile.read_bytes())
            info.update(CFBundleIdentifier=TEST_ID, CFBundleVersion='1', CFBundleShortVersionString='0.0.1',
                        OrbitUpdaterLocalTest=True, SUPublicEDKey=public.read_text(),
                        SUFeedURL='http://127.0.0.1:%d/appcast.xml' % server.server_port,
                        NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
            info['SURequireSignedFeed'] = True
            infofile.write_bytes(plistlib.dumps(info))
            sign_chromium_bundle(base)
            # The transition source predates SURequireSignedFeed; every other build requires it.
            legacy = work / 'legacy/Orbit.app'
            legacy.parent.mkdir()
            copy(base, legacy)
            legacy_info = dict(info)
            legacy_info.pop('SURequireSignedFeed')
            (legacy / 'Contents/Info.plist').write_bytes(plistlib.dumps(legacy_info))
            sign_chromium_bundle(legacy)
            previous = None
            if transitions:
                # Strip release signing artifacts only from a disposable copy. The fixture
                # is re-signed for its confined mock identity by the normal packager.
                previous_source = work / 'previous-source/Orbit.app'
                previous_source.parent.mkdir()
                copy(args.previous_app, previous_source)
                for name in ('CodeResources', 'embedded.provisionprofile'):
                    (previous_source / 'Contents' / name).unlink(missing_ok=True)
                shutil.rmtree(previous_source / 'Contents/_CodeSignature', ignore_errors=True)
                previous = work / 'previous/Orbit.app'
                run(sys.executable, ROOT / 'scripts/orbit-app.py', 'build', '--synthetic',
                    '--source-app', previous_source, '--output', previous, '--synthetic-root', root,
                    '--bundle-id', 'lab.orbit.orbit.update-ux', stdout=subprocess.DEVNULL)
                previous_info = plistlib.loads((previous / 'Contents/Info.plist').read_bytes())
                previous_info.update(info)
                (previous / 'Contents/Info.plist').write_bytes(plistlib.dumps(previous_info))
                sign_chromium_bundle(previous)
            sparkle = ROOT / '.tools/sparkle-2.10.1/bin/sign_update'
            builds = {}
            for version in ('2', '3'):
                target = work / ('target-%s/Orbit.app' % version)
                target.parent.mkdir()
                copy(base, target)
                info.update(CFBundleVersion=version, CFBundleShortVersionString='0.0.' + version)
                (target / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                sign_chromium_bundle(target)
                builds[version] = target
                archive = feed / ('update-%s.zip' % version)
                run('/usr/bin/ditto', '-c', '-k', '--keepParent', target, archive)
                signature = subprocess.check_output([str(sparkle), '--ed-key-file', str(key), str(archive)], text=True).strip()
                xml = ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                       '<sparkle:version>%s</sparkle:version><sparkle:shortVersionString>0.0.%s</sparkle:shortVersionString>'
                       '<enclosure url="http://127.0.0.1:%d/update-%s.zip" type="application/octet-stream" %s/>'
                       '</item></channel></rss>') % (version, version, server.server_port, version, signature)
                (work / ('unsigned-%s.xml' % version)).write_text(xml)
                (work / ('valid-%s.xml' % version)).write_text(xml)
                run(sparkle, '--ed-key-file', key, work / ('valid-%s.xml' % version), stdout=subprocess.DEVNULL)
            def signed_feed(path, content):
                path.write_text(content)
                run(sparkle, '--ed-key-file', key, path, stdout=subprocess.DEVNULL)
                return path.read_bytes()
            empty = signed_feed(work / 'empty.xml', '<rss><channel/></rss>')
            broken = signed_feed(work / 'broken.xml', re.sub(
                r'sparkle:edSignature="[^"]+"', 'sparkle:edSignature="' + base64.b64encode(bytes(64)).decode() + '"',
                (work / 'unsigned-2.xml').read_text()))
            # Same length, valid signature trailer: only the feed signature check can reject it.
            tampered = (work / 'valid-3.xml').read_bytes().replace(b'0.0.3</sparkle:short', b'0.0.9</sparkle:short')
            if tampered == (work / 'valid-3.xml').read_bytes():
                raise RuntimeError('Tampered feed fixture did not change')
            installed = work / 'installed/Orbit.app'
            installed.parent.mkdir()
            for name in args.cases:
                if name == 'auth-transition':
                    run_auth_transition(work, root, args.evidence, args.auth_expect, previous, builds, feed,
                                        empty, packaging)
                    continue
                if (args.evidence / 'STOP-CRASH').exists():
                    raise RuntimeError('Crash: stop all GUI qualification')
                if installed.exists():
                    shutil.rmtree(installed)
                if root.exists():
                    shutil.rmtree(root)
                (work / 'requests.log').unlink(missing_ok=True)
                packaging.prepare_synthetic_root(root, TEST_ID)
                source = (previous if name == 'engine-transition' else legacy if name == 'signed-transition'
                          else builds['2'] if name in SIGNED_NEXT_CASES else base)
                copy(source, installed)
                content = (work / ('valid-%s.xml' % case_versions(name)[1])).read_bytes()
                if name == 'manual':
                    content = empty
                if name == 'broken':
                    content = broken
                if name == 'signed-tampered':
                    content = tampered
                if name == 'signed-unsigned':
                    content = (work / 'unsigned-3.xml').read_bytes()
                (feed / 'appcast.xml').write_bytes(content)
                run('/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__, '--case', name,
                    '--work', work, '--evidence', args.evidence)
        finally:
            server.shutdown()
            server.server_close()
            authentication.shutdown()
            authentication.server_close()


if __name__ == '__main__':
    main()
