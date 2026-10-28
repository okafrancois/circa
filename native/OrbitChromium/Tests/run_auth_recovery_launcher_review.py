#!/usr/bin/env python3
"""Compile the actual product launcher; exercise only inert runtime-free synthetic starts."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--modules', type=Path, required=True,
                    help='Actual BrowserCore module/library produced by test-synthetic-startup.py')
parser.add_argument('--scratch', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
scratch = args.scratch.resolve()
scratch.mkdir(parents=True, exist_ok=False)
modules = args.modules.resolve()
tests = Path(__file__).resolve().parent
env = repo / 'native/Sources/Orbit/Environment'
launcher = repo / 'native/OrbitChromium/App/EngineComposition+Chromium.swift'
flags = ['swiftc', '-swift-version', '6', '-j', '2', '-num-threads', '2',
         '-module-cache-path', str(scratch / 'module-cache')]


def compile_to_log(command, name):
    with (scratch / (name + '.log')).open('wb') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)


# Empty imported engine modules let the exact launcher body compile with the local boundary
# doubles. They contain no engine implementation and link no CEF or personal data provider.
empty = scratch / 'Empty.swift'
empty.write_text('// Inert import module for launcher source verification.\n')
for module in ['BrowserEngine', 'ChromiumEngine']:
    compile_to_log(flags + ['-parse-as-library', '-emit-module', '-module-name', module,
                           '-emit-module-path', str(scratch / (module + '.swiftmodule')), str(empty)], module)
executable = scratch / 'launcher-inert'
sources = [env / name for name in ['OrbitBuildIdentity.swift', 'OrbitProductConfiguration.swift',
                                    'SyntheticDataGuard.swift', 'LaunchConfiguration.swift']]
sources += [launcher, tests / 'AuthenticationLauncherIndependentReview.swift']
compile_to_log(flags + ['-parse-as-library', '-I', str(modules), '-L', str(modules), '-lBrowserCore',
                       '-I', str(scratch)] + [str(p) for p in sources] + ['-o', str(executable)], 'launcher')
results = []
stages = ['cold-launch-install', 'hook-factory', 'hook-will-start', 'hook-switches', 'hook-hidden',
          'runtime-options', 'runtime-shared', 'runtime-run']
for case in ['ordinary', 'intent-only', 'work-only', 'intent-writing', 'pending-without-provider',
             'fresh-auth-profile', 'fresh-auth-marker', 'busy-instance']:
    with tempfile.TemporaryDirectory(prefix='orbit-inert-launch-review-') as temporary:
        root = Path(temporary).resolve() / 'root'
        root.mkdir(mode=0o700)
        (root / 'Chromium').mkdir(mode=0o700)
        session = root / 'session.json'
        session.write_bytes(b'invented-session-url-fixture')
        session.chmod(0o600)
        if case in ['intent-only', 'pending-without-provider']:
            (root / '.orbit-auth-recovery-required').write_bytes(b'invented-required-intent')
            (root / '.orbit-auth-recovery-required').chmod(0o600)
        if case in ['work-only', 'pending-without-provider']:
            (root / '.orbit-auth-recovery').mkdir(mode=0o700)
        if case == 'intent-writing':
            (root / '.orbit-auth-recovery-required.writing').write_bytes(b'incomplete-intent')
            (root / '.orbit-auth-recovery-required.writing').chmod(0o600)
        if case == 'fresh-auth-profile':
            (root / 'Chromium/Auth-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa').mkdir(mode=0o700)
        if case == 'fresh-auth-marker':
            (root / 'Chromium/.orbit-auth-synthetic').write_bytes(b'orbit-auth-synthetic-v1\n')
            (root / 'Chromium/.orbit-auth-synthetic').chmod(0o600)
        descriptor = None
        try:
            if case == 'busy-instance':
                descriptor = os.open(root / '.orbit-instance.lock', os.O_RDWR | os.O_CREAT, 0o600)
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            child = subprocess.run([str(executable), '--use-mock-keychain', '--orbit-data-root=' + str(root),
                                    '--session-file', str(session), 'https://launch-fixture.test/'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
            observed = child.stdout.decode().splitlines()
            expected_exit = 0 if case == 'ordinary' else 64 if case == 'busy-instance' else 65
            assert child.returncode == expected_exit, (case, child.returncode)
            assert observed == (stages if case == 'ordinary' else []), (case, observed)
            if expected_exit == 65:
                assert child.stderr == b'orbit: authentication recovery refused before runtime\n', case
            assert session.read_bytes() == b'invented-session-url-fixture', case
            results.append({'case': case, 'exit': child.returncode, 'stages': observed,
                            'sessionUnchanged': True, 'joined': True})
        finally:
            if descriptor is not None:
                os.close(descriptor)
evidence = {'sourcesSHA256': {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
            'cases': results, 'actualLauncherBody': True, 'inertBoundaryDoubles': True,
            'CEFLinkedOrRun': False, 'applicationCreated': False}
(scratch / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
print('PASS actual launcher: ordinary startup reaches inert hooks/runtime; seven refusals execute no stage')
