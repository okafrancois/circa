#!/usr/bin/env python3
"""Qualify native diagnostics and extension preferences in a confined product."""
import argparse
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('weekly_security', REPO / 'scripts/orbit-engine-security-smoke.py')
security = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(security)
validation = security.validation
lab = validation.lab


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    data = root / 'data'
    extension = root / 'extension'
    extension.mkdir(exist_ok=False)
    (extension / 'manifest.json').write_text(json.dumps({
        'manifest_version': 3, 'name': 'Weekly fixture', 'version': '1.0',
        'options_ui': {'page': 'options.html', 'open_in_tab': True}}))
    (extension / 'options.html').write_text('<!doctype html><title>Weekly options</title><p>Synthetic options</p>')
    state = data / 'perf-state.json'
    control = data / 'perf-command.json'
    nonce = str(time.monotonic_ns())
    def timeout(*_):
        raise TimeoutError('45-second GUI lease')
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(35)
    started = time.monotonic()
    lab.APP = args.app.resolve()
    with lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
                '--perf-probe', '--orbit-security-fixture', f'--load-extension={extension}',
                f'--orbit-data-root={data}'], stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 12
                while not state.exists():
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    if time.monotonic() > deadline: raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                temporary = data / 'perf-command.pending'
                temporary.write_text(json.dumps({'command': 'native-weekly', 'nonce': nonce}))
                temporary.replace(control)
                while time.monotonic() < started + 30:
                    try: result = json.loads(state.read_text())
                    except (OSError, ValueError): result = {}
                    if result.get('commandNonce') == nonce and 'nativeWeekly' in result:
                        checks = result['nativeWeekly']; break
                    time.sleep(.05)
                else: raise TimeoutError('Native weekly probe')
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=10)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    checks['guiSeconds'] = time.monotonic() - started
    (root / 'verification.json').write_text(json.dumps(checks, indent=2) + '\n')
    required = {'taskCapability', 'taskAccepted', 'taskOwnedWindow', 'taskClosed', 'traceCapability',
        'traceStarted', 'duplicateBeginRefused', 'escapeRefused', 'traceCompleted', 'duplicateEndRefused',
        'optionsCapability', 'incognitoCapability', 'hasOptionsPage', 'canAllowIncognito',
        'incognitoInitiallyOff', 'optionsOpened', 'optionsNavigated', 'incognitoEnabled', 'incognitoReset'}
    assert all(checks.get(name) is True for name in required), checks
    trace = Path(checks['tracePath']).resolve()
    assert data.resolve() in trace.parents and trace.stat().st_size == checks['traceBytes'] > 0
    assert isinstance(json.loads(trace.read_text())['traceEvents'], list)
    assert checks['optionsURL'] == 'chrome-extension://' + checks['extensionID'] + '/options.html'
    assert not (data / 'escape.json').exists()
    print('Native weekly smoke: %d checks passed; trace written; clean shutdown; %.2f s GUI lease' %
          (len(required), checks['guiSeconds']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    args = parser.parse_args()
    validation.validate_bundle(args.app.resolve(), args.output.resolve())
    if args.phase:
        phase(args); return
    assert not (args.output / 'data/perf-state.json').exists(), 'Use a fresh synthetic root'
    subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
        '--app', str(args.app.resolve()), '--output', str(args.output.resolve()), '--phase'], check=True)


if __name__ == '__main__':
    main()
