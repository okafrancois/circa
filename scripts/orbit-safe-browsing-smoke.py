#!/usr/bin/env python3
"""Qualify opt-in Safe Browsing in a confined bundle, using invalid mock credentials only."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time
from urllib.parse import parse_qs, urlsplit

REPO = Path(__file__).resolve().parents[1]
FIXTURE_KEY = 'synthetic-invalid-safe-browsing-key'
BUNDLE_ID = 'lab.orbit.orbit.sec-safebrowsing'


def validate_bundle(app, data):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info.get('CFBundleIdentifier') == BUNDLE_ID
    assert info.get('OrbitSyntheticBundle') is True and info.get('OrbitUseMockKeychain') is True
    assert info.get('OrbitDataRoot') == str(data)
    assert not data.is_symlink()
    assert json.loads((data / '.orbit-synthetic-root').read_text()) == {
        'bundleID': BUNDLE_ID, 'owner': os.getuid(), 'version': 1}


def summarize_network(root, data, phase):
    file = data / 'Chromium/safe-browsing-netlog.json'
    raw = file.read_text()
    events = json.loads(raw)['events']
    sources = set()
    requests = {}
    for event in events:
        url = event.get('params', {}).get('url', '')
        parsed = urlsplit(url)
        if parsed.hostname in ('safebrowsing.googleapis.com', 'safebrowsing.google.com', 'sb-ssl.google.com'):
            sources.add(event['source']['id'])
            requests[url] = {
                'endpoint': parsed.scheme + '://' + parsed.netloc + parsed.path,
                'keyMatchesFixture': parse_qs(parsed.query).get('key') == [FIXTURE_KEY]}
    responses = [event for event in events if event['source']['id'] in sources
                 and ('headers' in event.get('params', {}) or 'net_error' in event.get('params', {}))]
    redacted = raw.replace(FIXTURE_KEY, '[REDACTED]')
    (root / (phase + '-netlog-redacted.json')).write_text(redacted)
    file.unlink()
    return {'safeBrowsingRequests': list(requests.values()), 'eventCount': len(events),
            'responses': json.loads(json.dumps(responses).replace(FIXTURE_KEY, '[REDACTED]'))}


def phase_run(args):
    root, app = args.output.resolve(), args.app.resolve()
    data = root / 'data'
    validate_bundle(app, data)
    spec = importlib.util.spec_from_file_location('safe_browsing_lab', REPO / 'scripts/orbit-chromium-lab.py')
    lab = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lab)
    lab.APP = app
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    state.unlink(missing_ok=True)
    control.unlink(missing_ok=True)
    settings = data / 'session.json.settings.json'
    settings.write_text(json.dumps({'version': 2, 'reducedMotion': 'system', 'profiles': [], 'spaces': [],
                                    'safeBrowsingEnabled': args.phase in ('on', 'no-key')}))
    command = [str(app / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--orbit-data-root=' + str(data),
               '--perf-probe', '--orbit-safe-browsing-fixture']
    if args.phase != 'no-key':
        command.append('--orbit-safe-browsing-fixture-key')
    outputs = []
    started = time.monotonic()

    def timeout(*_):
        raise TimeoutError('52-second GUI lease')

    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(52)
    with lab.OwnedProcessRun() as owner:
        with (root / (args.phase + '-stdout.log')).open('w') as out, \
                (root / (args.phase + '-stderr.log')).open('w') as err:
            process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)

            def request(values):
                nonce = str(time.monotonic_ns())
                temporary = data / 'command.pending'
                temporary.write_text(json.dumps(dict(values, nonce=nonce, command='safe-browsing')))
                temporary.replace(control)
                deadline = time.monotonic() + 22
                while time.monotonic() < deadline:
                    try:
                        result = json.loads(state.read_text())
                        if result.get('commandNonce') == nonce:
                            return result['safeBrowsing']
                    except (FileNotFoundError, json.JSONDecodeError):
                        pass
                    assert process.poll() is None, 'Synthetic process exited before response'
                    time.sleep(.05)
                raise TimeoutError('Synthetic command response')

            try:
                deadline = time.monotonic() + 14
                while True:
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    try:
                        ready = json.loads(state.read_text())
                    except (FileNotFoundError, json.JSONDecodeError):
                        ready = {}
                    if ready.get('interactiveUptime') and ready.get('windowNumber') and ready.get('browsers', 0) > 0:
                        break
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                time.sleep(.25)
                outputs.append(request({}))
                if args.phase == 'captures':
                    for appearance in ('light', 'dark'):
                        for row in ('off', 'on-no-key', 'on-key'):
                            outputs.append(request({'state': row, 'appearance': appearance}))
                else:
                    # Observe beyond the accelerated initial update interval (5-10 seconds).
                    time.sleep(max(0, 20 - (time.monotonic() - started)))
                    if args.phase == 'on':
                        outputs.append(request({'navigation': 'test'}))
                        outputs.append(request({'state': 'off'}))
                    elif args.phase == 'off':
                        outputs.append(request({'state': 'on-key'}))
                    else:
                        outputs.append(request({}))
            finally:
                try:
                    if process.poll() is None:
                        control.write_text('{"command":"quit"}')
                        process.wait(timeout=10)
                finally:
                    # The ownership helper always cleans up, even after timeout/cancellation.
                    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    summary = {'phase': args.phase, 'exit': process.returncode, 'seconds': round(time.monotonic() - started, 2),
               'checks': outputs, **summarize_network(root, data, args.phase)}
    for file in (root / (args.phase + '-stdout.log'), root / (args.phase + '-stderr.log'), settings):
        assert FIXTURE_KEY not in file.read_text(), 'Credential appeared outside secure storage'
    (root / (args.phase + '-verification.json')).write_text(json.dumps(summary, indent=2) + '\n')
    enabled = args.phase == 'on'
    assert outputs and outputs[0]['launchEnabled'] == enabled
    assert all(check['globalPreference'] == enabled and check['profilePreference'] == enabled for check in outputs)
    requests = summary['safeBrowsingRequests']
    if enabled:
        assert requests and any(request['keyMatchesFixture'] for request in requests), 'Runtime key path did not take effect'
        assert outputs[1]['testPageCommitted'] and not outputs[1]['testPageInterstitial']
    else:
        assert not requests, 'Disabled Safe Browsing attempted network traffic'
    print(f"Safe Browsing {args.phase}: passed; {len(requests)} unique requests; normal shutdown; {summary['seconds']} seconds")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='Bundle must bake <output>/data as its synthetic root')
    parser.add_argument('--phase', choices=['off', 'on', 'no-key', 'captures'], required=True)
    parser.add_argument('--locked', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    validate_bundle(args.app.resolve(), args.output.resolve() / 'data')
    if args.locked:
        phase_run(args)
    else:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable,
                        __file__, '--app', str(args.app.resolve()), '--output', str(args.output.resolve()),
                        '--phase', args.phase, '--locked'], check=True)


if __name__ == '__main__':
    main()
