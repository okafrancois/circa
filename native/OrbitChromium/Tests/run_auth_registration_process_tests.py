#!/usr/bin/env python3
"""Registered recovery across separate native processes, fake storage only; no engine or app."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--modules', type=Path, required=True)
parser.add_argument('--scratch', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
scratch = args.scratch.resolve(); scratch.mkdir(parents=True, exist_ok=False)
modules = args.modules.resolve()
environment = repo / 'native/Sources/Orbit/Environment'
sources = [environment / name for name in ['OrbitBuildIdentity.swift', 'OrbitProductConfiguration.swift', 'SyntheticDataGuard.swift', 'LaunchConfiguration.swift']]
sources.append(Path(__file__).with_name('AuthenticationRegistrationProcessTests.swift'))
executable = scratch / 'registration-process'
with (scratch / 'build.log').open('wb') as log:
    subprocess.run(['swiftc', '-swift-version', '6', '-j', '2', '-num-threads', '2', '-parse-as-library',
                    '-module-cache-path', str(scratch / 'module-cache'), '-I', str(modules), '-L', str(modules),
                    '-lBrowserCore'] + [str(p) for p in sources] + ['-o', str(executable)],
                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)


def run(home, mode, expected, output):
    child = subprocess.Popen([str(executable), mode, str(home)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        stdout, stderr = child.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        child.kill(); child.communicate(); raise AssertionError('Owned offline process exceeded deadline')
    assert child.returncode == expected, (mode, child.returncode)
    assert stdout == (output + '\n').encode() and stderr == b'', mode
    return {'mode': mode, 'exit': child.returncode, 'joined': True}


results = []
profile = 'Chromium/profile-11111111-1111-1111-1111-111111111111'
other = 'Chromium/profile-22222222-2222-2222-2222-222222222222'
for case in ['restart', 'missing-key', 'wrong-key', 'registration-replaced']:
    with tempfile.TemporaryDirectory(prefix='orbit-registered-process-') as temporary:
        home = Path(temporary).resolve(); root = home / 'root'; root.mkdir(mode=0o700)
        for directory in ['Chromium', profile, other]: (root / directory).mkdir(mode=0o700)
        for path, value in {profile + '/Cookies': b'invented-original', other + '/Cookies': b'invented-sibling',
                            'session.json': b'invented-session', '.orbit-auth-recovery-synthetic': b'orbit-auth-recovery-synthetic-v1\n'}.items():
            (root / path).write_bytes(value); (root / path).chmod(0o600)
        children = [run(home, 'prepare', 0, 'prepared-registered-evidence')]
        registration = root / '.orbit-auth-root-registration'; before = registration.read_bytes(); inode = registration.stat().st_ino
        storage = home / 'fake-storage'; storage_before = storage.read_bytes()
        if case == 'missing-key': storage.unlink()
        if case == 'wrong-key':
            import plistlib
            rows = plistlib.loads(storage_before)
            # The disposable fake's protected value changes only in memory/on this private file.
            value = bytearray(rows[0]['v_Data']); value[-1] ^= 1; rows[0]['v_Data'] = bytes(value)
            storage.write_bytes(plistlib.dumps(rows, fmt=plistlib.FMT_BINARY))
        if case == 'registration-replaced':
            registration.rename(root / 'saved-registration'); registration.write_bytes(before); registration.chmod(0o600)
        refused = case != 'restart'
        children.append(run(home, 'recover', 65 if refused else 0,
                            'refused-runtime-not-linked' if refused else 'admitted-load-only-runtime-not-linked'))
        assert (root / (profile + '/Cookies')).read_bytes() == (b'changed' if refused else b'invented-original')
        assert (root / (other + '/Cookies')).read_bytes() == b'invented-sibling'
        assert registration.read_bytes() == before
        if not refused:
            assert registration.stat().st_ino == inode and storage.read_bytes() == storage_before
            children.append(run(home, 'recover', 0, 'admitted-load-only-runtime-not-linked'))
        if case == 'missing-key': assert not storage.exists()
        results.append({'case': case, 'children': children, 'registrationBytesPreserved': True,
                        'siblingPreserved': True, 'refusalStateUnchanged': refused})
(scratch / 'results.json').write_text(json.dumps({'sourcesSHA256': {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    'cases': results, 'storage': 'disposable fake sibling file only', 'CEFOrAppLinked': False, 'SecItemCalled': False}, indent=2) + '\n')
print('PASS separate registered processes: stable identity, load-only rollback/reopen, missing/wrong key, replaced registration')
