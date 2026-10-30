#!/usr/bin/env python3
"""Download inert loopback fixtures in a confined hidden bundle; never open them."""
import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import zipfile

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('quarantine_lab', REPO / 'scripts/orbit-chromium-lab.py')
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


def fixtures():
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, 'w') as zipped:
        zipped.writestr(zipfile.ZipInfo('Fixture.app/Contents/Info.plist'), plistlib.dumps({
            'CFBundleIdentifier': 'invalid.synthetic.fixture', 'CFBundlePackageType': 'APPL',
            'CFBundleExecutable': 'Fixture', 'CFBundleName': 'Synthetic Fixture', 'CFBundleVersion': '1'}))
        executable = zipfile.ZipInfo('Fixture.app/Contents/MacOS/Fixture')
        executable.create_system = 3
        executable.external_attr = 0o100755 << 16
        zipped.writestr(executable, b'#!/bin/sh\nexit 0\n')
    return {'fixture.app.zip': archive.getvalue(), 'ordinary.txt': b'Synthetic ordinary download\n'}


class Fixture(BaseHTTPRequestHandler):
    files = fixtures()

    def log_message(self, *_):
        pass

    def do_GET(self):
        name = self.path.removeprefix('/')
        if name in self.files:
            body = self.files[name]
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', f'attachment; filename="{name}"')
        elif name == 'source':
            body = ('<!doctype html><title>Synthetic downloads</title>' + ''.join(
                f'<a id="{name}" href="/{name}">{name}</a>' for name in self.files)).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
        else:
            self.send_error(404)
            return
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def validate_bundle(app, root):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    identifier = info.get('CFBundleIdentifier', '')
    data = root / 'data'
    if not (info.get('OrbitSyntheticBundle') is True and info.get('OrbitUseMockKeychain') is True
            and info.get('LSFileQuarantineEnabled') is True and identifier.startswith('lab.orbit.orbit.')
            and info.get('OrbitDataRoot') == str(data)):
        raise ValueError('A confined synthetic bundle with quarantine enabled is required')
    marker = data / '.orbit-synthetic-root'
    if data.is_symlink() or marker.is_symlink() or json.loads(marker.read_text()) != {
            'bundleID': identifier, 'owner': os.getuid(), 'version': 1}:
        raise ValueError('Synthetic data root ownership mismatch')


def phase(args):
    started = time.monotonic()
    root = args.output.resolve()
    validate_bundle(args.app, root)
    lab.APP = args.app.resolve()
    directory = root / 'phase'
    directory.mkdir(mode=0o700)
    (directory / '.orbit-chromium-lab').write_text(lab.MARKER)
    command = [str(args.app / 'Contents/MacOS/Orbit'), '--use-mock-keychain',
               f'--orbit-data-root={root}/data', f'--orbit-smoke-run={directory}',
               f'--orbit-smoke-fixture=http://127.0.0.1:{args.port}/',
               '--orbit-smoke-phase=fresh', '--orbit-smoke-quarantine']
    with lab.OwnedProcessRun() as owner:
        with (directory / 'stdout.log').open('w') as out, (directory / 'stderr.log').open('w') as err:
            process = owner.launch(command, stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                process.wait(timeout=22)
            except subprocess.TimeoutExpired:
                pass
    results = json.loads((directory / 'results.json').read_text())
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    assert not results['aborted'] and all(r['status'] != 'failed' for r in results['results'])
    assert results['hidden']['violations'] == []
    results['sessionSeconds'] = time.monotonic() - started
    assert results['sessionSeconds'] < 30
    (root / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Bundle must be baked with --synthetic-root <output>/data')
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    if args.phase:
        phase(args)
        return
    root = args.output.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    assert not (root / 'phase').exists(), 'Use a fresh output directory'
    (root / '.orbit-chromium-lab').write_text(lab.MARKER)
    validate_bundle(args.app, root)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', 'python3', __file__,
                        '--app', str(args.app.resolve()), '--output', str(root), '--phase',
                        '--port', str(server.server_port)], check=True)
        evidence = {}
        for name, expected in server.RequestHandlerClass.files.items():
            file = root / 'phase' / name
            assert file.read_bytes() == expected
            quarantine = subprocess.check_output(['xattr', '-p', 'com.apple.quarantine', file], text=True).strip()
            assert quarantine
            encoded = subprocess.check_output(['xattr', '-px', 'com.apple.metadata:kMDItemWhereFroms', file], text=True)
            origins = plistlib.loads(bytes.fromhex(encoded))
            assert origins == [f'http://127.0.0.1:{server.server_port}/{name}',
                               f'http://127.0.0.1:{server.server_port}/source']
            deadline = time.monotonic() + 8
            while True:
                metadata = subprocess.check_output(['mdls', '-name', 'kMDItemWhereFroms', file], text=True).strip()
                if all(source in metadata for source in origins) or time.monotonic() >= deadline:
                    break
                time.sleep(0.2)
            assert all(source in metadata for source in origins), metadata
            evidence[name] = {'quarantine': quarantine, 'whereFroms': origins, 'mdls': metadata}
        (root / 'metadata.json').write_text(json.dumps(evidence, indent=2) + '\n')
        print(json.dumps(evidence, indent=2))
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


if __name__ == '__main__':
    main()
