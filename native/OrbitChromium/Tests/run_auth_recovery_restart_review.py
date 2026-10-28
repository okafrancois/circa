#!/usr/bin/env python3
"""Independent AES-GCM/filesystem recovery across completely separate offline processes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--modules', type=Path, required=True)
parser.add_argument('--scratch', type=Path, required=True)
args = parser.parse_args()
modules = args.modules.resolve()
scratch = args.scratch.resolve()
scratch.mkdir(parents=True, exist_ok=False)
source = Path(__file__).with_name('AuthenticationRecoveryRestartIndependentReview.swift')
executable = scratch / 'recovery-offline'
with (scratch / 'build.log').open('wb') as log:
    subprocess.run(['swiftc', '-swift-version', '6', '-j', '2', '-num-threads', '2', '-parse-as-library',
                    '-module-cache-path', str(scratch / 'module-cache'), '-I', str(modules), '-L', str(modules),
                    '-lBrowserCore', str(source), '-o', str(executable)], stdout=log, stderr=subprocess.STDOUT,
                   check=True, timeout=120)
profile = 'Chromium/profile-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
other = 'Chromium/profile-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
results = []


def child(root, operation, expected):
    result = subprocess.run([str(executable), operation, str(root)], capture_output=True, timeout=20)
    assert result.returncode == expected, (operation, result.returncode)
    assert not result.stderr, operation
    assert result.stdout in [b'prepared-applying\n', b'recovery-complete-runtime-not-linked\n',
                             b'restore-interrupted-runtime-not-linked\n', b'recovery-refused-runtime-not-linked\n']
    return result.returncode


for case in ['normal-restart', 'interrupted-restart', 'wrong-key', 'missing-key', 'corrupt-last-chunk']:
    with tempfile.TemporaryDirectory(prefix='orbit-process-recovery-review-') as temporary:
        home = Path(temporary).resolve()
        home.chmod(0o700)
        root = home / 'root'
        root.mkdir(mode=0o700)
        for directory in ['Chromium', profile, other, 'Import', 'History']:
            (root / directory).mkdir(mode=0o700)
        original = {profile + '/Cookies': b'original-cookie-fixture', profile + '/multi': bytes([29]) * 524301,
                    other + '/Cookies': b'unrelated-cookie-fixture', 'session.json': b'original-session-fixture',
                    'Import/mapping': b'original-mapping-fixture', 'History/history.sqlite': b'original-history-fixture',
                    'History/history.sqlite-wal': b'original-wal-fixture', 'Chromium/Local State': b'original-local-state-fixture',
                    '.orbit-auth-recovery-synthetic': b'orbit-auth-recovery-synthetic-v1\n'}
        for path, data in original.items():
            (root / path).write_bytes(data)
            (root / path).chmod(0o600)
        key = home / 'independent-key'
        key.write_bytes(os.urandom(32))
        key.chmod(0o600)
        statuses = [child(root, 'prepare', 0)]
        ownership = ['', 'Chromium', profile, '.orbit-instance.lock', '.orbit-auth-recovery', '.orbit-auth-recovery/lock']
        inodes = [(root / name).stat().st_ino for name in ownership]
        work = root / '.orbit-auth-recovery'
        if case == 'wrong-key':
            key.write_bytes(os.urandom(32))
        elif case == 'missing-key':
            key.unlink()
        elif case == 'corrupt-last-chunk':
            chunk = sorted(work.glob('chunk-*'))[-1]
            data = bytearray(chunk.read_bytes())
            data[-1] ^= 1
            chunk.write_bytes(data)
        if case == 'interrupted-restart':
            statuses.append(child(root, 'interrupt', 70))
        refused = case in ['wrong-key', 'missing-key', 'corrupt-last-chunk']
        statuses.append(child(root, 'recover', 65 if refused else 0))
        if refused:
            assert (root / (profile + '/Cookies')).read_bytes() == b'changed-cookie-fixture'
            assert (root / 'session.json').read_bytes() == b'changed-session-fixture'
        else:
            for path, data in original.items():
                assert (root / path).read_bytes() == data, path
            assert not (root / 'profile-mapping.json').exists()
        assert inodes == [(root / name).stat().st_ino for name in ownership]
        assert (root / '.orbit-auth-recovery-required').exists() and (work / 'manifest').exists()
        results.append({'case': case, 'childExits': statuses, 'allChildrenJoined': True,
                        'ownershipInodesUnchanged': True, 'evidenceRetained': True,
                        'currentStateUntouchedOnRefusal': refused, 'exactFixtureRestored': not refused})
(scratch / 'results.json').write_text(json.dumps({'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'cases': results, 'keyOutsideBackup': True, 'sourceKeyOrSnapshot': False, 'CEFLinkedOrRun': False}, indent=2) + '\n')
print('PASS separate-process recovery: exact rollback, interrupted replay, wrong/missing key and late corruption')
