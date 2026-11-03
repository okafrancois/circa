#!/usr/bin/env python3
"""Reproduce popup load cancellation using a confined bundle and a static MV3 fixture."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('popup_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)
lab = validation.lab


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    lab.APP = args.app.resolve()
    data = root / 'data'
    control = data / 'perf-command.json'
    state = data / 'perf-state.json'
    def expired(*_):
        raise TimeoutError('Bounded popup GUI lease')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(45)
    assert not state.exists(), 'Use a fresh synthetic root'
    extension = args.extension_dir.resolve() if args.extension_dir else REPO / 'native/OrbitChromium/Tests/PopupLifecycleExtension'
    assert extension.is_dir() and not extension.is_symlink()
    if args.extension_id:
        assert re.fullmatch('[a-p]{32}', args.extension_id), 'Invalid synthetic extension identity'
    with lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
                '--perf-probe', f'--orbit-data-root={data}',
                '--load-extension=' + str(extension)],
                stdout=out, stderr=err, stdin=subprocess.DEVNULL,
                env=dict(os.environ, ORBIT_EXTENSION_DIAGNOSTICS="1"))
            result = {}
            try:
                deadline = time.monotonic() + 15
                while True:
                    assert process.poll() is None, 'Exited during startup'
                    assert time.monotonic() < deadline, 'Startup timeout'
                    try:
                        ready = json.loads(state.read_text())
                    except (OSError, ValueError):
                        ready = {}
                    if ready.get('pid') == process.pid and ready.get('interactiveUptime'):
                        break
                    time.sleep(.05)
                nonce = str(time.monotonic_ns())
                command = {'command': 'extension-controls', 'action': args.action, 'nonce': nonce,
                           'base': f'http://127.0.0.1:{args.port}/'}
                if args.extension_id:
                    command['extensionID'] = args.extension_id
                pending = data / 'command.pending'
                pending.write_text(json.dumps(command))
                pending.replace(control)
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline and process.poll() is None:
                    try:
                        result = json.loads(state.read_text())
                    except (OSError, ValueError):
                        result = {}
                    if result.get('commandNonce') == nonce and 'extensionControls' in result:
                        break
                    time.sleep(.05)
                (root / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
                if args.action == 'cancel-loading':
                    time.sleep(6)  # Include cold extension renderer startup after anchor removal.
                if process.poll() is not None:
                    raise AssertionError(f'Popup process exited: {process.returncode}')
                checks = result.get('extensionControls', {})
                required = (['survivedCancellation', 'sourceReady'] if args.action == 'cancel-loading'
                            else ['sidebarFloatingBeforeAction', 'popupVisibleAfterLoad', 'sidebarFloatingAfterPopup', 'sourceStayedVisible']
                            if args.action == 'pinned-popup' else ['siteActionSurvived', 'popupVisible'])
                assert all(checks.get(key) is True for key in required), checks
            finally:
                if process.poll() is None:
                    control.write_text('{"command":"quit"}')
                    process.wait(timeout=4)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    print('Popup lifecycle passed:', args.action)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--action', choices=['cancel-loading', 'site-popup', 'pinned-popup'], default='cancel-loading')
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    parser.add_argument('--extension-dir', type=Path)
    parser.add_argument('--extension-id')
    args = parser.parse_args()
    validation.validate_bundle(args.app.resolve(), args.output.resolve())
    if args.phase:
        phase(args)
        return
    server = ThreadingHTTPServer(('127.0.0.1', 0), validation.Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        command = ['/usr/bin/lockf', '-t', '1', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
            '--app', str(args.app.resolve()), '--output', str(args.output.resolve()), '--phase',
            '--action', args.action, '--port', str(server.server_port)]
        if args.extension_dir:
            command += ['--extension-dir', str(args.extension_dir.resolve())]
        if args.extension_id:
            command += ['--extension-id', args.extension_id]
        subprocess.run(command, check=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    main()
