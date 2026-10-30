#!/usr/bin/env python3
"""Verify a native PDF survives a clean process restart in a confined r13 product bundle."""
import argparse
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('local_restore_validation', REPO / 'scripts/orbit-password-store-smoke.py')
validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validation)
lab = validation.lab


def pdf_fixture(path):
    stream = b'BT /F1 24 Tf 72 720 Td (Synthetic local document restoration) Tj ET\n'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
               b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'endstream']
    data, offsets = b'%PDF-1.4\n', [0]
    for index, body in enumerate(objects, 1):
        offsets.append(len(data))
        data += f'{index} 0 obj\n'.encode() + body + b'\nendobj\n'
    start = len(data)
    data += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    data += b''.join(f'{offset:010} 00000 n \n'.encode() for offset in offsets[1:])
    data += f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()
    path.write_bytes(data)


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    lab.APP = args.app.resolve()
    data = root / 'data'
    pdf_fixture(data / 'synthetic.pdf')
    state, command = data / 'perf-state.json', data / 'perf-command.json'
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('50-second GUI lease')))
    signal.alarm(50)
    evidence = []
    for phase_name in ('open', 'restore'):
        state.unlink(missing_ok=True)
        with lab.OwnedProcessRun() as owner:
            with (root / f'{phase_name}-stdout.log').open('w') as out, (root / f'{phase_name}-stderr.log').open('w') as err:
                process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
                                        '--perf-probe', f'--orbit-data-root={data}'],
                                       stdin=subprocess.DEVNULL, stdout=out, stderr=err)

                def wait_for(predicate, timeout=12):
                    deadline = time.monotonic() + timeout
                    while time.monotonic() < deadline:
                        assert process.poll() is None, 'Owned synthetic app exited early'
                        try:
                            current = json.loads(state.read_text())
                            if current.get('pid') == process.pid and predicate(current):
                                return current
                        except (OSError, ValueError):
                            pass
                        time.sleep(.05)
                    raise TimeoutError(f'{phase_name}: probe response')

                def send(operation, name='local-files'):
                    # The in-process probe verifies its own PID and window controller before
                    # performing any native operation; no OS keyboard/pointer events are used.
                    nonce = str(time.monotonic_ns())
                    pending = command.with_suffix('.pending')
                    pending.write_text(json.dumps({'command': name, 'nonce': nonce, 'operation': operation}))
                    pending.replace(command)
                    if name != 'quit':
                        return wait_for(lambda value: value.get('commandNonce') == nonce)

                wait_for(lambda _: True)
                if phase_name == 'open':
                    send('typed')
                for _ in range(3):
                    result = send('restore-check')
                    local = result['localFiles']
                    if local.get('loading') is False:
                        break
                assert local.get('pid') == process.pid and local.get('isFile') is True, local
                assert local.get('fileTabs') == 1 and local.get('loading') is False, local
                assert local['document']['contentType'] == 'application/pdf', local
                targets = local.get('targets', {}).get('targetInfos', [])
                assert any(target['url'].startswith('chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/')
                           for target in targets), 'PDF viewer component missing'
                assert any(target['type'] in ('iframe', 'webview') and target['url'].endswith('/synthetic.pdf')
                           for target in targets), 'Native PDF content target missing'
                captures = data / 'captures'
                for path in captures.glob('*.png'):
                    path.replace(root / f'{phase_name}-{path.name}')
                evidence.append({'phase': phase_name, 'pid': process.pid, 'localFiles': local})
                send('', name='quit')
                process.wait(timeout=10)
                assert process.returncode == 0, 'Clean application quit required'
        assert not owner.remaining and not owner.forced_signals, 'Owned process group must exit normally'
    assert evidence[0]['pid'] != evidence[1]['pid']
    (root / 'verification.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('Real r13 PDF open, clean quit, relaunch and restored PDF viewer: passed (2 process runs).')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--phase', action='store_true')
    args = parser.parse_args()
    if args.phase:
        phase(args)
    else:
        validation.validate_bundle(args.app.resolve(), args.output.resolve())
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
                        '--phase', '--app', str(args.app), '--output', str(args.output)], check=True)


if __name__ == '__main__':
    main()
