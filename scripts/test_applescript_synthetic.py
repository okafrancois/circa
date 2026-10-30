#!/usr/bin/env python3
"""Run fixed in-process, self-targeted OSA probes in an offscreen synthetic bundle."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time

LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
BUNDLE_ID = 'lab.orbit.orbit.applescript-verify'


def consent_requested(log):
    # Identity construction logs "Prompting policy" even when no authorization is requested.
    return bool(re.search(
        r'(?i)(AUTHREQ_PROMPTING|will prompt|display.*prompt|request.*consent|'
        r'AUTHREQ_CTX:.*service=kTCCServiceAppleEvents, preflight=no)', log))


def read_state(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def run_session(args):
    app = args.app.resolve(strict=True)
    root = args.root.resolve(strict=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    identifier = info['CFBundleIdentifier']
    assert identifier == args.bundle_id == BUNDLE_ID, 'Explicit test identity required'
    assert info.get('OrbitSyntheticBundle') and info.get('OrbitUseMockKeychain'), 'Synthetic bundle required'
    assert Path(info['OrbitDataRoot']).resolve() == root and (root / '.orbit-synthetic-root').is_file()
    assert not str(app).startswith(('/Applications/', str(Path.home() / 'Applications') + '/'))
    subprocess.run([LSREGISTER, '-f', str(app)], check=True, capture_output=True, timeout=3)
    process = monitor = None
    started = time.monotonic()
    deadline = started + 48
    tcc_log = root / 'scripting-tcc.log'
    try:
        with (root / 'scripting-process.log').open('w') as output, tcc_log.open('w') as tcc:
            process = subprocess.Popen([str(app / 'Contents/MacOS' / info['CFBundleExecutable']),
                                        '--ephemeral', '--scripting-test-offscreen', '--perf-probe'],
                                       stdout=output, stderr=output, start_new_session=True)
            predicate = ('process == "tccd" AND (eventMessage CONTAINS "%d" OR '
                         'eventMessage CONTAINS "%s")') % (process.pid, identifier)
            monitor = subprocess.Popen(['/usr/bin/log', 'stream', '--style', 'compact', '--level', 'debug',
                                        '--predicate', predicate], stdout=tcc, stderr=tcc)
            time.sleep(0.5)
            assert monitor.poll() is None, 'TCC monitoring unavailable; probe not started'
            # No Apple Events leave this process; only the app runs its fixed self-targeted script.
            while time.monotonic() < deadline:
                assert process.poll() is None, (
                    'Test bundle exited (status %s); stop at first crash' % process.returncode)
                assert monitor.poll() is None, 'TCC monitor stopped'
                if consent_requested(tcc_log.read_text()):
                    raise RuntimeError('TCC consent requested; stopping without interacting')
                state = read_state(root / 'perf-state.json')
                if state.get('pid') == process.pid:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError('Startup timed out')
            (root / 'perf-command.json').write_text(json.dumps(
                {'command': 'scripting-self', 'operation': args.operation, 'nonce': args.operation}))
            while time.monotonic() < deadline:
                assert process.poll() is None, (
                    'Test bundle exited (status %s); stop at first crash' % process.returncode)
                assert monitor.poll() is None, 'TCC monitor stopped'
                if consent_requested(tcc_log.read_text()):
                    raise RuntimeError('TCC consent requested; stopping without interacting')
                perf = read_state(root / 'perf-state.json')
                if perf.get('pid') == process.pid and perf.get('scripting', {}).get('refused'):
                    raise RuntimeError('Synthetic self-target admission refused: ' + json.dumps(perf['scripting']))
                state = read_state(root / 'scripting-state.json')
                if state.get('pid') == process.pid and state.get('status') in ('passed', 'failed'):
                    print(json.dumps(state, sort_keys=True), flush=True)
                    if state['status'] != 'passed':
                        raise RuntimeError('Probe failed at ' + state.get('stage', 'unknown'))
                    print(json.dumps({'pid': process.pid, 'operation': args.operation,
                                      'elapsed': round(time.monotonic() - started, 2), 'tccPrompt': False}))
                    return
                time.sleep(0.05)
            raise RuntimeError('Self-targeted OSA timed out; stop without interacting with consent UI')
    finally:
        for child in (process, monitor):
            if child and child.poll() is None:
                if child is process:
                    os.killpg(child.pid, signal.SIGTERM)
                else:
                    child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
        subprocess.run([LSREGISTER, '-u', str(app)], capture_output=True, timeout=2)
        subprocess.run(['/usr/bin/defaults', 'delete', identifier], capture_output=True, timeout=2)
        subprocess.run(['/usr/bin/tccutil', 'reset', 'AppleEvents', identifier], capture_output=True, timeout=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--bundle-id', default=BUNDLE_ID)
    parser.add_argument('--operation', choices=('spike', 'full'), default='spike')
    parser.add_argument('--locked-session', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not args.locked_session:
        return subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable,
                               str(Path(__file__).resolve()), *sys.argv[1:], '--locked-session']).returncode
    try:
        run_session(args)
    except (AssertionError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
