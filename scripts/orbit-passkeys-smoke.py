#!/usr/bin/env python3
"""Qualify WebAuthn ceremonies in a confined, mock-Keychain Chromium test bundle.

Registration and sign-in run against the engine's DevTools virtual authenticator on a
localhost fixture (and optionally on webauthn.io). A final ceremony without any virtual
authenticator opens the engine's own authenticator dialog, which is captured and cancelled.
No real authenticator, account, Keychain item or system passkey is touched.
"""
import argparse
import functools
import http.server
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('passkeys_security', REPO / 'scripts/orbit-engine-security-smoke.py')
security = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(security)
validation = security.validation
lab = validation.lab
BUNDLE_ID = 'lab.orbit.orbit.passkeys-system'

FIXTURE = '''<!doctype html><meta charset="utf-8"><title>Passkey fixture</title><h1>Passkey fixture</h1>
<script>
const bytes = n => crypto.getRandomValues(new Uint8Array(n));
const b64 = buffer => btoa(String.fromCharCode(...new Uint8Array(buffer)));
let credentialId = null, controller = null;
async function register() {
  const credential = await navigator.credentials.create({publicKey: {
    challenge: bytes(32), rp: {name: 'Fixture', id: location.hostname},
    user: {id: bytes(16), name: 'synthetic@example.test', displayName: 'Synthetic'},
    pubKeyCredParams: [{type: 'public-key', alg: -7}, {type: 'public-key', alg: -257}],
    authenticatorSelection: {residentKey: 'required', userVerification: 'required'}, attestation: 'none'}});
  credentialId = credential.rawId;
  const client = JSON.parse(new TextDecoder().decode(credential.response.clientDataJSON));
  return {type: credential.type, attachment: credential.authenticatorAttachment, clientType: client.type,
          origin: client.origin, transports: credential.response.getTransports(),
          attestationBytes: credential.response.attestationObject.byteLength,
          serialized: JSON.stringify(credential).includes(credential.id)};
}
async function login(discoverable) {
  const credential = await navigator.credentials.get({publicKey: {challenge: bytes(32), rpId: location.hostname,
    userVerification: 'required', allowCredentials: discoverable ? [] : [{type: 'public-key', id: credentialId}]}});
  const client = JSON.parse(new TextDecoder().decode(credential.response.clientDataJSON));
  const flags = new Uint8Array(credential.response.authenticatorData)[32];
  return {sameCredential: b64(credential.rawId) === b64(credentialId), clientType: client.type,
          userPresent: !!(flags & 1), userVerified: !!(flags & 4), signatureBytes: credential.response.signature.byteLength,
          userHandle: !!credential.response.userHandle};
}
function openDialog() {
  controller = new AbortController();
  globalThis.dialogOutcome = 'pending';
  navigator.credentials.create({signal: controller.signal, publicKey: {challenge: bytes(32),
    rp: {name: 'Fixture', id: location.hostname}, user: {id: bytes(16), name: 'dialog@example.test', displayName: 'Dialog'},
    pubKeyCredParams: [{type: 'public-key', alg: -7}]}})
    .then(() => globalThis.dialogOutcome = 'created', e => globalThis.dialogOutcome = e.name);
  return true;
}
async function cancelDialog() {
  controller.abort();
  for (let i = 0; i < 50 && globalThis.dialogOutcome === 'pending'; ++i) await new Promise(r => setTimeout(r, 50));
  return globalThis.dialogOutcome;
}
</script>'''

# webauthn.io is a public test site. Only an invented username is submitted.
WAIT = """const wait = async (test, ms = 15000) => { const end = Date.now() + ms;
  while (Date.now() < end) { const v = test(); if (v) return v; await new Promise(r => setTimeout(r, 100)); } return null; };"""
WEBAUTHN_IO_REGISTER = '(async () => {' + WAIT + """
  document.querySelector('#input-email').value = 'circa-synthetic-' + Date.now();
  document.querySelector('#register-button').click();
  return {registered: !!await wait(() => /Success! Now try to authenticate/i.test(document.body.innerText))};
})()"""
# Signing in navigates, so the click is deferred and the outcome is read from the next document.
WEBAUTHN_IO_LOGIN = "setTimeout(() => document.querySelector('#login-button').click(), 0), true"
WEBAUTHN_IO_CHECK = '(async () => {' + WAIT + """
  return {authenticated: !!await wait(() => /You're logged in!/i.test(document.body.innerText))};
})()"""


class Server:
    def __enter__(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = FIXTURE.encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *_):
                pass
        self.httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        return 'http://localhost:%d/' % self.httpd.server_address[1]

    def __exit__(self, *_):
        self.httpd.shutdown()


def phase(args):
    root = args.output.resolve()
    validation.validate_bundle(args.app.resolve(), root)
    data = root / 'data'
    state, control = data / 'perf-state.json', data / 'perf-command.json'
    def timeout(*_):
        raise TimeoutError('GUI lease')
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(58)
    started = time.monotonic()
    steps = {}
    lab.APP = args.app.resolve()

    def send(step, key=None, **fields):
        nonce = str(time.monotonic_ns())
        temporary = data / 'perf-command.pending'
        temporary.write_text(json.dumps(dict(fields, command='passkeys', step=step, nonce=nonce)))
        temporary.replace(control)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try: result = json.loads(state.read_text())
            except (OSError, ValueError): result = {}
            if result.get('commandNonce') == nonce and 'passkeys' in result:
                steps[key or step] = result['passkeys']
                return result['passkeys']
            time.sleep(.05)
        raise TimeoutError(step)

    def evaluate(name, expression):
        reply = send('evaluate', name, expression=expression)
        assert not reply.get('exception'), (name, reply)
        return reply['value']

    with Server() as fixture, lab.OwnedProcessRun() as owner:
        with (root / 'stdout.log').open('w') as out, (root / 'stderr.log').open('w') as err:
            process = owner.launch([str(lab.APP / 'Contents/MacOS/Orbit'), '--use-mock-keychain', '--perf-probe',
                f'--orbit-data-root={data}'], stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 15
                while not state.exists():
                    assert process.poll() is None, 'Synthetic process exited before readiness'
                    if time.monotonic() > deadline: raise TimeoutError('Synthetic startup')
                    time.sleep(.05)
                assert send('open', url=fixture)['loaded']
                # The engine's own dialog first, before any DevTools WebAuthn environment exists.
                send('dialog-start', expression='openDialog()')
                send('dialog-capture', 'create', name='create')
                if args.hybrid:
                    send('dialog-press', 'hybrid-press', label='phone')
                    time.sleep(4)
                    send('dialog-capture', 'hybrid', name='hybrid')
                evaluate('dialog-cancel', 'cancelDialog()')
                assert send('authenticator', transport='internal')['added']
                evaluate('register', 'register()')
                evaluate('login', 'login(false)')
                evaluate('discoverable-login', 'login(true)')
                send('credentials')
                send('disable')
                assert send('authenticator', 'usb-authenticator', transport='usb')['added']
                evaluate('usb-register', 'register()')
                evaluate('usb-login', 'login(false)')
                send('disable', 'usb-disable')
                if args.webauthn_io:
                    assert send('open', 'webauthn-io-open', url='https://webauthn.io/')['loaded']
                    assert send('authenticator', 'webauthn-io-authenticator', transport='internal')['added']
                    evaluate('webauthn-io-register', WEBAUTHN_IO_REGISTER)
                    evaluate('webauthn-io-login', WEBAUTHN_IO_LOGIN)
                    for attempt in range(4):
                        if evaluate('webauthn-io-check', WEBAUTHN_IO_CHECK):
                            break
                        time.sleep(.5)
                    send('credentials', 'webauthn-io-credentials')
                    send('disable', 'webauthn-io-disable')
                    assert send('open', 'fixture-reopen', url=fixture)['loaded']
            finally:
                control.write_text('{"command":"quit"}')
                process.wait(timeout=10)
    signal.alarm(0)
    steps['guiSeconds'] = time.monotonic() - started
    (root / 'verification.json').write_text(json.dumps(steps, indent=2) + '\n')
    assert process.returncode == 0 and not owner.remaining and not owner.forced_signals
    verify(steps, fixture, args.webauthn_io, args.hybrid)

def verify(steps, fixture, webauthn_io, hybrid):
    for prefix, attachment in (('', 'platform'), ('usb-', 'cross-platform')):
        registration = steps[prefix + 'register']['value']
        assert registration['type'] == 'public-key' and registration['clientType'] == 'webauthn.create', registration
        assert registration['attachment'] == attachment and registration['attestationBytes'] > 0, registration
        assert registration['origin'] == fixture.rstrip('/') and registration['serialized'], registration
        assertion = steps[prefix + 'login']['value']
        assert assertion['sameCredential'] and assertion['userPresent'] and assertion['userVerified'], assertion
    assert steps['discoverable-login']['value']['userHandle'] and steps['discoverable-login']['value']['sameCredential']
    assert steps['credentials']['count'] == 1 and steps['credentials']['resident'] == 1
    assert steps['credentials']['rpIds'] == ['localhost']
    if webauthn_io:
        assert steps['webauthn-io-register']['value'] == {'registered': True}, steps['webauthn-io-register']
        assert steps['webauthn-io-check']['value'] == {'authenticated': True}, steps['webauthn-io-check']
        assert steps['webauthn-io-credentials']['signCounts'] == [2]
        assert steps['webauthn-io-credentials']['rpIds'] == ['webauthn.io']
    dialog = steps['create']['windows']
    assert dialog and all(window['captured'] for window in dialog), dialog
    if hybrid:
        # The engine opens the combined QR + security-key sheet directly when Bluetooth is ready,
        # otherwise after the phone row is pressed. That sheet is far taller than the chooser
        # (565 versus 387 points at the default text size).
        assert steps['hybrid']['windows'][0]['height'] > 480, steps['hybrid']
    assert steps['dialog-cancel']['value'] in ('AbortError', 'NotAllowedError'), steps['dialog-cancel']
    print('Passkeys smoke: platform + USB virtual ceremonies%s passed; engine dialog shown (%d window) and cancelled; '
          '%.1f s GUI lease' % (', webauthn.io' if webauthn_io else '', len(dialog), steps['guiSeconds']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='Synthetic bundle with id ' + BUNDLE_ID)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--webauthn-io', action='store_true', help='Also register and sign in on webauthn.io')
    parser.add_argument('--hybrid', action='store_true', help='Also open the phone (hybrid) step and capture it')
    parser.add_argument('--phase', action='store_true')
    args = parser.parse_args()
    validation.validate_bundle(args.app.resolve(), args.output.resolve())
    if args.phase:
        phase(args); return
    assert not (args.output / 'data/perf-state.json').exists(), 'Use a fresh synthetic root'
    command = ['/usr/bin/lockf', '-k', '/tmp/orbit-gui-slot.lock', sys.executable, __file__,
               '--app', str(args.app.resolve()), '--output', str(args.output.resolve()), '--phase']
    if args.webauthn_io:
        command.append('--webauthn-io')
    if args.hybrid:
        command.append('--hybrid')
    subprocess.run(command, check=True)


if __name__ == '__main__':
    main()
