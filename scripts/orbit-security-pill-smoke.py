#!/usr/bin/env python3
"""Check committed address and connection controls on confined loopback fixtures."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import ssl
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('engine_security_fixture', REPO / 'scripts/orbit-engine-security-smoke.py')
security = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(security)
validation, lab = security.validation, security.lab


class Fixture(security.Fixture):
    def do_GET(self):
        if self.path == '/slow':
            time.sleep(1)
        if self.path == '/mixed-displayed':
            body = ('<!doctype html><title>Displayed mixed fixture</title><img src="http://mixed.example.invalid:%d/pixel.svg">' % self.http_port).encode()
        elif self.path == '/pixel.svg':
            body = b'<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="green"/></svg>'
        else:
            return super().do_GET()
        self.send_response(200)
        self.send_header('Content-Type', 'image/svg+xml' if self.path == '/pixel.svg' else 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    lab.APP = args.app.resolve()
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    nonce = str(time.monotonic_ns())
    def timeout(*_):
        raise TimeoutError('55-second GUI lease')
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(55)
    started = time.monotonic()
    with lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--perf-probe',
                '--orbit-security-fixture', f'--orbit-security-spki={args.spki}', f'--orbit-data-root={data}'], stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 15
                while not state.exists():
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    if time.monotonic() > deadline: raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                command = {'command': 'security-pill', 'nonce': nonce, 'url': f'http://127.0.0.1:{args.port}/', 'tls': args.tls, 'trusted': args.trusted}
                temporary = data / 'perf-command.pending'
                temporary.write_text(json.dumps(command)); temporary.replace(control)
                deadline = time.monotonic() + 35
                while time.monotonic() < deadline:
                    try: result = json.loads(state.read_text())
                    except (OSError, ValueError): result = {}
                    if result.get('commandNonce') == nonce and 'securityPill' in result:
                        checks = result['securityPill']; break
                    time.sleep(.05)
                else: raise TimeoutError('Security pill probe')
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=4)
    signal.alarm(0)
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    checks['guiSeconds'] = time.monotonic() - started
    (root / 'verification.json').write_text(json.dumps(checks, indent=2) + '\n')
    assert checks['pushState']['unchanged'], checks
    assert checks['slowPending'] == {'unchanged': True, 'loading': True}, checks
    assert checks['slowCommitted']['value'].endswith('/slow'), checks
    for name in ('neutral', 'certificate-error', 'mixed-displayed', 'mixed-ran'):
        assert checks[name]['glyph'] == 'lock.slash.fill', checks
        assert checks[name]['connectionLabel'] == 'Connection is not secure', checks
    assert checks['certificate-error']['certificateError'] and checks['certificate-error']['interstitial'], checks
    assert checks['mixed-displayed']['displayed'] and checks['mixed-ran']['ran'] and checks['mixedExecuted']['ran'], checks
    assert checks['secure']['glyph'] == 'lock.fill' and checks['secure']['connectionLabel'] == 'Secure connection', checks
    assert checks['homograph']['label'] == f'xn--pple-43d.com:{args.port}', checks
    for name in ('data', 'blob'):
        assert checks[name]['label'] == 'Page' and checks[name]['value'] == 'Page' and checks[name]['glyph'] == 'none', checks
    captures = list((data / 'captures').glob('*.png'))
    assert len(captures) == 32, len(captures)
    print('Security pill smoke passed; 32 captures; clean shutdown; %.2f s GUI lease' % checks['guiSeconds'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phase', action='store_true')
    parser.add_argument('--port', type=int)
    parser.add_argument('--tls')
    parser.add_argument('--trusted')
    parser.add_argument('--spki')
    args = parser.parse_args()
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    if args.phase:
        phase(args); return
    assert not (root / 'data/perf-state.json').exists(), 'Use a fresh synthetic root'
    materials = []
    def certificate(name):
        key, cert = root / (name + '-key.pem'), root / (name + '-cert.pem')
        materials.extend([key, cert])
        subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=127.0.0.1',
            '-addext', 'subjectAltName=IP:127.0.0.1', '-keyout', str(key), '-out', str(cert)], check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.chmod(key, 0o600)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        return server, cert
    http = ThreadingHTTPServer(('127.0.0.1', 0), Fixture); Fixture.http_port = http.server_port
    tls, _ = certificate('invalid')
    trusted, cert = certificate('trusted')
    public = subprocess.run(['/usr/bin/openssl', 'x509', '-in', str(cert), '-pubkey', '-noout'], check=True, capture_output=True).stdout
    der = subprocess.run(['/usr/bin/openssl', 'pkey', '-pubin', '-outform', 'DER'], input=public, check=True, capture_output=True).stdout
    spki = base64.b64encode(hashlib.sha256(der).digest()).decode()
    for server in (http, tls, trusted):
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__, '--app', str(args.app.resolve()),
            '--output', str(root), '--phase', '--port', str(http.server_port), '--tls', 'https://127.0.0.1:%d' % tls.server_port,
            '--trusted', 'https://127.0.0.1:%d' % trusted.server_port, '--spki', spki], check=True)
    finally:
        for server in (http, tls, trusted): server.shutdown(); server.server_close()
        for path in materials: path.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
