#!/usr/bin/env python3
"""Run the focused r17 E1/E4 gate in a confined synthetic product bundle."""
import argparse
import importlib.util
import json
import plistlib
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('password_store_lab', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab
LEASE_SECONDS = 54.0
PROCESS_START_BUDGET = 8.0
PROBE_BUDGET = 36.0


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.split('?', 1)[0] != '/freeze':
            self.send_error(404)
            return
        body = (b'<!doctype html><meta charset="utf-8"><title>Synthetic lifecycle fixture</title>'
                b'<p>Silent, local lifecycle test page.</p>')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class SocketListener:
    def __init__(self):
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('127.0.0.1', 0))
        self.sock.listen(4)
        self.sock.settimeout(.1)
        self.port = self.sock.getsockname()[1]
        self.count = 0
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while True:
            try:
                client, _ = self.sock.accept()
            except (OSError, TimeoutError):
                if self.sock.fileno() < 0:
                    return
                continue
            with self.lock:
                self.count += 1
            client.close()

    def close(self):
        self.sock.close()
        self.thread.join(timeout=.5)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.pending')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def seed_preferences(root):
    data = root / 'data'
    chromium = data / 'Chromium'
    if data.is_symlink() or chromium.is_symlink():
        raise ValueError('Synthetic profile roots cannot be symlinks')
    off_profile, on_profile = uuid.uuid4(), uuid.uuid4()
    space_id, window_id = uuid.uuid4(), uuid.uuid4()

    def raw(value):
        return {'rawValue': str(value).upper()}

    session = {
        'version': 4,
        'profiles': [{'id': raw(off_profile), 'name': 'Synthetic'}],
        'spaces': [{'id': raw(space_id), 'name': 'Synthetic', 'profileID': raw(off_profile)}],
        'tabs': [],
        'themeImports': [],
        'organization': {
            'archive': [],
            'archivePolicy': {'defaultThreshold': {'kind': 'after', 'seconds': 43200},
                              'maximumArchivedTabs': 1000, 'profileThresholds': []},
            'archivedSpaces': [], 'favorites': [], 'folders': [], 'spaces': [], 'splits': [], 'tabs': []
        },
        'windows': [{
            'id': raw(window_id), 'activeSpaceID': raw(space_id),
            'placement': {'height': 720, 'isFullScreen': False, 'sidebarWidth': 228,
                          'width': 1020, 'x': 120, 'y': 80},
            'spaces': [{'spaceID': raw(space_id), 'occurrenceIDs': []}]
        }]
    }
    chromium.mkdir(parents=True, exist_ok=True)
    write_json(data / 'session.json', session)
    profiles = {}
    for profile_id, value in ((off_profile, 2), (on_profile, 0)):
        profile_dir = chromium / ('profile-' + str(profile_id).lower())
        profile_dir.mkdir(parents=True, exist_ok=False)
        preference_path = profile_dir / 'Preferences'
        write_json(preference_path, {'net': {'network_prediction_options': value}})
        profiles[str(profile_id).upper()] = {
            'seededValue': value,
            'preferencesPath': str(preference_path),
            'sha256': __import__('hashlib').sha256(preference_path.read_bytes()).hexdigest()
        }
    proof = {
        'preferenceKey': 'net.network_prediction_options',
        'values': {'disabled': 2, 'standard': 0},
        'offProfileID': str(off_profile).upper(),
        'onProfileID': str(on_profile).upper(),
        'seededBeforeProcessLaunch': True,
        'profiles': profiles
    }
    write_json(root / 'preference-seed.json', proof)
    return proof


def remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise TimeoutError('54-second monotonic GUI lease exhausted')
    return value


def run_cleanup(app, root, deadline):
    commands = [
        ['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(app)],
        ['/usr/bin/defaults', 'delete', 'lab.orbit.orbit.engine-r17'],
        ['/usr/bin/tccutil', 'reset', 'All', 'lab.orbit.orbit.engine-r17']
    ]
    outcomes = []
    for command in commands:
        try:
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=min(2.0, remaining(deadline)))
            outcomes.append({'argv': command, 'exitCode': result.returncode,
                             'stdout': result.stdout.strip(), 'stderr': result.stderr.strip()})
        except (OSError, subprocess.TimeoutExpired, TimeoutError) as error:
            outcomes.append({'argv': command, 'error': type(error).__name__, 'detail': str(error)})
    write_json(root / 'cleanup.json', outcomes)
    return outcomes


def phase(args, lease_started):
    root = args.output.resolve()
    app = args.app.resolve()
    validation.validate_bundle(app, root)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'lab.orbit.orbit.engine-r17':
        raise ValueError('Unexpected synthetic bundle identifier')
    if info.get('OrbitSyntheticBundle') is not True or info.get('OrbitUseMockKeychain') is not True:
        raise ValueError('Synthetic ownership and mock Keychain are required')
    if time.monotonic() - lease_started >= PROCESS_START_BUDGET:
        raise TimeoutError('Synthetic launch start budget exhausted')

    seed = json.loads((root / 'preference-seed.json').read_text())
    listeners = [SocketListener() for _ in range(7)]
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    nonce = str(time.monotonic_ns())
    owner = lab.OwnedProcessRun()
    process = None
    receipt = None
    checks = {}
    result = {}
    probe_started = None
    primary_error = None
    try:
        with owner:
            with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
                process = owner.launch([str(app / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--perf-probe',
                    f'--orbit-data-root={data}'], stdout=out, stderr=err, stdin=subprocess.DEVNULL)
                startup_deadline = min(lease_started + PROCESS_START_BUDGET, time.monotonic() + 7)
                while not state.exists() and time.monotonic() < startup_deadline:
                    if process.poll() is not None:
                        raise RuntimeError('Synthetic process exited before perf-state readiness')
                    time.sleep(min(.05, remaining(startup_deadline)))
                if not state.exists():
                    raise TimeoutError('Synthetic perf-state readiness timed out')

                command = {
                    'command': 'native-r17', 'nonce': nonce,
                    'url': f'http://127.0.0.1:{server.server_port}/freeze',
                    'ports': ','.join(str(listener.port) for listener in listeners),
                    'offProfileID': seed['offProfileID'], 'onProfileID': seed['onProfileID']
                }
                probe_started = time.monotonic()
                write_json(data / 'perf-command.pending', command)
                (data / 'perf-command.pending').replace(control)
                receipt_deadline = min(probe_started + 4, lease_started + 13)
                while time.monotonic() < receipt_deadline:
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    candidate = result.get('commandReceipt')
                    if isinstance(candidate, dict) and candidate.get('nonce') == nonce:
                        receipt = candidate
                        break
                    time.sleep(min(.05, remaining(receipt_deadline)))
                if receipt is None:
                    raise TimeoutError('Probe command receipt absent; state=' + json.dumps(result, sort_keys=True))
                if result.get('commandNonce') != nonce:
                    raise RuntimeError('Receipt was written without the command nonce acknowledgement')

                probe_deadline = min(probe_started + PROBE_BUDGET + .5, lease_started + 48)
                while time.monotonic() < probe_deadline:
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'nativeR17' in result:
                        checks = result['nativeR17']
                        break
                    if process.poll() is not None:
                        raise RuntimeError('Synthetic process exited during native-r17 probe')
                    time.sleep(min(.05, remaining(probe_deadline)))
                else:
                    progress = result.get('nativeR17Progress', {})
                    checks = {'probeTimedOut': True, 'progressTrace': progress}

                checks['commandReceipt'] = receipt
                checks['progressTrace'] = result.get('nativeR17Progress', {})
                checks['nativeCommandNoncePersistedAtCompletion'] = result.get('commandNonce') == nonce
                checks['preferenceSeed'] = seed
                for listener in listeners:
                    listener.lock.acquire()
                    listener.lock.release()
                settle_deadline = min(time.monotonic() + 1.2, lease_started + 49)
                while time.monotonic() < settle_deadline:
                    if listeners[0].count > 0 and listeners[1].count == 0:
                        break
                    time.sleep(min(.05, remaining(settle_deadline)))
                checks['preconnectAcceptedSocketsByPort'] = [listener.count for listener in listeners]
                checks['e1RuntimeQualified'] = checks.get('e1RuntimeQualified') is True
                checks['e4PreferenceOffQualified'] = (
                    checks.get('e4PreferenceCallsQualified') is True
                    and listeners[0].count > 0 and listeners[1].count == 0
                )
                checks['runtimeStatus'] = {
                    'E1': 'QUALIFIED' if checks['e1RuntimeQualified'] else 'NOT QUALIFIED',
                    'E4 preference off': 'QUALIFIED' if checks['e4PreferenceOffQualified'] else 'NOT QUALIFIED'
                }
            if process is not None and process.poll() is None:
                control.write_text('{"command":"quit"}')
                try:
                    process.wait(timeout=min(3.0, max(.1, remaining(lease_started + 52))))
                except (subprocess.TimeoutExpired, TimeoutError):
                    checks['normalQuitTimedOut'] = True
        if process is not None and process.returncode == 0 and not owner.remaining and not owner.forced_signals:
            checks['normalQuit'] = True
        else:
            checks['normalQuit'] = False
    except BaseException as error:
        primary_error = {'type': type(error).__name__, 'detail': str(error)}
        raise
    finally:
        checks['process'] = {
            'pid': process.pid if process else None,
            'returnCode': process.returncode if process else None,
            'forcedSignals': owner.forced_signals,
            'remaining': owner.remaining,
            'cleanupErrors': owner.cleanup_errors,
            'primaryError': primary_error
        }
        checks['preconnectAcceptedSocketsByPort'] = [listener.count for listener in listeners]
        checks['preconnectPortOrder'] = {'enabledPositiveControl': listeners[0].port,
                                         'disabledProfile': listeners[1].port}
        checks['guiSecondsIncludingLockLaunchQuitAndCleanup'] = time.monotonic() - lease_started
        (root / 'verification.json').write_text(json.dumps(checks, indent=2, sort_keys=True) + '\n')
        cleanup = run_cleanup(app, root, lease_started + LEASE_SECONDS - 1)
        checks['ownedCleanup'] = cleanup
        (root / 'verification.json').write_text(json.dumps(checks, indent=2, sort_keys=True) + '\n')
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=.5)
        for listener in listeners:
            listener.close()
        checks['guiSecondsIncludingAllCleanup'] = time.monotonic() - lease_started
        (root / 'verification.json').write_text(json.dumps(checks, indent=2, sort_keys=True) + '\n')
        if checks['guiSecondsIncludingAllCleanup'] >= LEASE_SECONDS:
            raise TimeoutError('54-second monotonic GUI lease exceeded')
    print(json.dumps(checks['runtimeStatus'] if 'runtimeStatus' in checks else checks, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--lease-started', type=float)
    args = parser.parse_args()
    root = args.output.resolve()
    app = args.app.resolve()
    validation.validate_bundle(app, root)
    if args.phase:
        phase(args, args.lease_started if args.lease_started is not None else time.monotonic())
        return
    if (root / 'data/perf-state.json').exists() or (root / 'preference-seed.json').exists():
        raise SystemExit('Use a fresh synthetic root')
    seed_preferences(root)
    lease_started = time.monotonic()
    command = ['/usr/bin/lockf', '-t', '1', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
               '--app', str(app), '--output', str(root), '--phase', '--lease-started', str(lease_started)]
    completed = subprocess.run(command, check=False, timeout=LEASE_SECONDS - .5)
    elapsed = time.monotonic() - lease_started
    if completed.returncode != 0:
        raise SystemExit(f'GUI runner failed with status {completed.returncode} after {elapsed:.2f}s')
    if elapsed >= LEASE_SECONDS:
        raise SystemExit(f'GUI lease was {elapsed:.2f}s, limit is {LEASE_SECONDS:.0f}s')


if __name__ == '__main__':
    main()
