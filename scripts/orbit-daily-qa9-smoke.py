#!/usr/bin/env python3
"""Bounded, offscreen regression probes on a synthetic Chromium product (no real updates)."""
import argparse
import ctypes
import importlib.util
import json
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('daily9_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)
lab = validation.lab


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if 'slow' in self.path:
            time.sleep(2)
        body = ("<!doctype html><title>Synthetic " + self.path.strip('/') + "</title>"
                + ('<textarea>' + ('hello WORLD' if self.path == '/editing' else '') + '</textarea><a href="/linked" target="_blank">Open link</a>')
                + ("<script>addEventListener('load',()=>{const t=document.querySelector('textarea');t.focus();t.select()})</script>" if self.path == '/editing' else '')).encode()
        if getattr(self, 'native_performance', False):
            body = b'<!doctype html><title>Synthetic page state</title><input id="input"><div contenteditable id="edit">Synthetic</div>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    lab.APP = args.app.resolve()
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    state.unlink(missing_ok=True)
    control.unlink(missing_ok=True)
    def expired(*_):
        raise TimeoutError('45-second GUI lease')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(45)
    started = time.monotonic()
    nonce = str(time.monotonic_ns())
    result = {}
    memory = {}
    with lab.OwnedProcessRun() as owner:
        with (root / (args.step + '-stdout.log')).open('w') as out, (root / (args.step + '-stderr.log')).open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
                '--perf-probe', '--daily-qa9-offscreen', f'--orbit-data-root={data}', '--orbit-performance'],
                stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            def read():
                try:
                    value = json.loads(state.read_text())
                    return value if value.get('pid') == process.pid else {}
                except (OSError, ValueError):
                    return {}
            try:
                deadline = time.monotonic() + 22
                while not read().get('interactiveUptime'):
                    assert process.poll() is None, 'Synthetic app exited before readiness; stop GUI QA'
                    if time.monotonic() > deadline:
                        raise TimeoutError('Synthetic startup')
                    time.sleep(.04)
                command = {'command': args.probe, 'step': args.step, 'nonce': nonce,
                           'base': f'http://127.0.0.1:{args.port}', 'url': f'http://127.0.0.1:{args.port}/'}
                pending = data / 'perf-command.pending'
                pending.write_text(json.dumps(command))
                pending.replace(control)
                deadline = time.monotonic() + 37
                while time.monotonic() < deadline:
                    result = read()
                    if result.get('commandNonce') == nonce and args.result_key in result:
                        if args.step == 'performance':
                            time.sleep(args.memory_settle)
                            rows = [list(map(int, row.split())) for row in subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,rss='], text=True).splitlines()]
                            pids = {process.pid}
                            for _ in range(8):
                                pids |= {pid for pid, parent, _ in rows if parent in pids}
                            class Usage(ctypes.Structure):
                                _fields_ = [('uuid', ctypes.c_uint8 * 16), ('values', ctypes.c_uint64 * 10)]
                            libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
                            footprints = []
                            for pid in pids:
                                usage = Usage()
                                if libproc.proc_pid_rusage(pid, 0, ctypes.byref(usage)) == 0:
                                    footprints.append(usage.values[7])
                            memory = {'shellRSSMiB': next(rss / 1024 for pid, _, rss in rows if pid == process.pid),
                                      'treeRSSMiB': sum(rss / 1024 for pid, _, rss in rows if pid in pids),
                                      'treeFootprintMiB': sum(footprints) / 2**20, 'processes': len(pids)}
                        break
                    assert process.poll() is None, 'Synthetic app exited during probe; stop GUI QA'
                    time.sleep(.04)
                else:
                    raise TimeoutError('Probe completion')
            finally:
                if process.poll() is None:
                    control.write_text('{"command":"quit"}')
                    process.wait(timeout=10)
    signal.alarm(0)
    record = {'pid': process.pid, 'seconds': time.monotonic() - started, 'exit': process.returncode,
              'remaining': owner.remaining, 'forcedSignals': owner.forced_signals, 'result': result, 'memory': memory}
    (root / (args.step + '-result.json')).write_text(json.dumps(record, indent=2) + '\n')
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals, 'Unclean exit; stop GUI QA'
    print(json.dumps({'step': args.step, 'seconds': record['seconds'], 'checks': result.get(args.result_key)}))
    checks = result.get(args.result_key, {})
    if args.probe == 'daily-qa9' and args.step == 'commands':
        required = {command + suffix for command in ('makeUpperCase', 'makeLowerCase', 'capitalize')
                    for suffix in ('SelectAll', 'SelectionReady', 'RegistryAccepted', 'RegistryDelivered', 'RegistryEffect',
                                   'MenuSelectAll', 'MenuAccepted', 'MenuEffect')}
        assert all(checks.get(key) is True for key in required), checks
    if args.probe == 'tab-ergonomics':
        required = {'duplicate', 'duplicateHistory', 'duplicateModelURL', 'duplicatePill', 'duplicateSidebar',
                    'duplicateDocument', 'forwardAccepted', 'duplicateForward', 'forwardDocument', 'duplicateIndependent'}
        assert all(checks.get(key) is True for key in required), checks
    failures = [key for key, value in checks.items() if value is False]
    if args.step == 'performance':
        assert checks.get('loaded') == checks.get('tabs') == 20, checks
    assert not failures, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--probe', default='daily-qa9')
    parser.add_argument('--result-key', default='dailyQA9')
    parser.add_argument('--step', default='tabs')
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    parser.add_argument('--seed', type=Path)
    parser.add_argument('--fresh', action='store_true')
    parser.add_argument('--relaunch', action='store_true')
    parser.add_argument('--memory-settle', type=float, default=0, choices=[0, 5])
    args = parser.parse_args()
    if args.phase:
        phase(args)
        return
    validation.validate_bundle(args.app.resolve(), args.output.resolve())
    if args.fresh:
        for child in (args.output.resolve() / 'data').iterdir():
            if child.name != '.orbit-synthetic-root':
                shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
    Fixture.native_performance = args.probe == 'native-performance'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        if args.seed:
            subprocess.run([str(args.seed.resolve()), str(args.output.resolve() / 'data/session.json'), f'http://127.0.0.1:{server.server_port}'], check=True)
        phase_command = ['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
            '--app', str(args.app.resolve()), '--output', str(args.output.resolve()), '--phase',
            '--port', str(server.server_port), '--probe', args.probe, '--result-key', args.result_key,
            '--step', args.step, '--memory-settle', str(args.memory_settle)]
        subprocess.run(phase_command, check=True, timeout=58)
        if args.relaunch:
            subprocess.run(phase_command + ['--step', 'restore'], check=True, timeout=58)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
