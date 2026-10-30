#!/usr/bin/env python3
"""Signed loopback update qualification. Builds must already exist; never uses the real feed/key.

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
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit

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


def case(work, name, evidence):
    """Invoked only under lockf by main; commands are consumed inside the PID-checked app."""
    deadline = time.monotonic() + 52
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
            command('seed')
            wait(lambda s: 'about:blank#update-session' in s.get('update', {}).get('tabs', []), 'seed')
            if name == 'manual':
                shutil.copyfile(work / 'valid.xml', work / 'feed/appcast.xml')
                time.sleep(.5)  # Let Sparkle finish scheduling after the previous cycle.
                command('check')
            if name == 'broken':
                wait(lambda _: 'aborted-code-' in log.read_text(), 'signature rejection')
                checks['broken_has_no_card'] = not state()['update']['card']
                shutil.copyfile(work / 'valid.xml', work / 'feed/appcast.xml')
                time.sleep(.5)  # Let Sparkle finish scheduling after the previous cycle.
                command('check')
            ready = wait(lambda s: s.get('update', {}).get('card') is True, 'prepared card')
            requests_before_click = archive_requests()
            checks['extracted_before_card'] = 'event=extracting ' in log.read_text()
            checks['staged_before_card'] = ready['update']['pending'] == '2' and ready['update']['version'] == '1'
            checks['no_standard_windows'] = not any('SU' in c or 'SPU' in c for c in ready['update']['windowClasses'])
            before = ready['update']['tabs']
            if name in ('off', 'toggle-off'):
                if name == 'toggle-off':
                    command('off')
                    ready = wait(lambda s: s.get('update', {}).get('automatic') is False, 'disable staged installation')
                checks['off_preference'] = ready['update']['automatic'] is False
                quit_app()
                checks['off_quit_preserves_old'] = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] == '1'
                launch(handle)
                wait(lambda s: s.get('update', {}).get('card') is True, 'restaged card')
            requests_before_click = archive_requests()
            if name == 'quit':
                quit_app()
                wait(lambda _: plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion'] == '2', 'install on quit')
                after = launch(handle)
            else:
                pid = state()['pid']
                command('click')
                after = wait(lambda s: s.get('pid') != pid and s.get('update', {}).get('version') == '2', 'relaunch')
            checks['no_download_on_click_or_quit'] = archive_requests() == requests_before_click
            checks['new_version'] = after['update']['version'] == '2'
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-app', type=Path, default=ROOT / 'native/OrbitChromium/build/app-orbit-engine-extensions-r13/product/Orbit.app')
    parser.add_argument('--evidence', type=Path, default=Path('/tmp/update-ux'))
    parser.add_argument('--case')
    parser.add_argument('--cases', nargs='+', default=['background', 'manual', 'quit', 'off', 'toggle-off', 'broken'],
                        choices=['background', 'manual', 'quit', 'off', 'toggle-off', 'broken'])
    parser.add_argument('--work', type=Path)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    if args.case:
        case(args.work, args.case, args.evidence)
        return
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
                    handle.write('archive\n' if self.path == '/update.zip' else 'feed\n')
                super().do_GET()
        server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=feed))
        threading.Thread(target=server.serve_forever, daemon=True).start()
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
            infofile.write_bytes(plistlib.dumps(info))
            sign_chromium_bundle(base)
            target = work / 'target/Orbit.app'
            target.parent.mkdir()
            copy(base, target)
            info.update(CFBundleVersion='2', CFBundleShortVersionString='0.0.2')
            (target / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            sign_chromium_bundle(target)
            archive = feed / 'update.zip'
            run('/usr/bin/ditto', '-c', '-k', '--keepParent', target, archive)
            sparkle = ROOT / '.tools/sparkle-2.10.1/bin/sign_update'
            signature = subprocess.check_output([str(sparkle), '--ed-key-file', str(key), str(archive)], text=True).strip()
            xml = ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                   '<sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.0.2</sparkle:shortVersionString>'
                   '<enclosure url="http://127.0.0.1:%d/update.zip" type="application/octet-stream" %s/>'
                   '</item></channel></rss>') % (server.server_port, signature)
            (work / 'valid.xml').write_text(xml)
            installed = work / 'installed/Orbit.app'
            installed.parent.mkdir()
            for name in args.cases:
                if (args.evidence / 'STOP-CRASH').exists():
                    raise RuntimeError('Crash: stop all GUI qualification')
                if installed.exists():
                    shutil.rmtree(installed)
                if root.exists():
                    shutil.rmtree(root)
                packaging.prepare_synthetic_root(root, TEST_ID)
                copy(base, installed)
                content = xml
                if name == 'manual':
                    content = '<rss><channel/></rss>'
                if name == 'broken':
                    import re
                    content = re.sub(r'sparkle:edSignature="[^"]+"', 'sparkle:edSignature="' + base64.b64encode(bytes(64)).decode() + '"', xml)
                (feed / 'appcast.xml').write_text(content)
                run('/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__, '--case', name,
                    '--work', work, '--evidence', args.evidence)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
