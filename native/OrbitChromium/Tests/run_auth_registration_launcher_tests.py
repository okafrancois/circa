#!/usr/bin/env python3
"""Compile the actual launcher with inert hooks; new registration refusals also reject old source.

No CEF library, application instance or SecItem call is used. Child processes are always joined.
The optional old-source comparison extracts exact Git blobs into disposable scratch, not a checkout.
"""
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
parser.add_argument('--compare-old', action='store_true')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
scratch = args.scratch.resolve()
scratch.mkdir(parents=True, exist_ok=False)
modules = args.modules.resolve()
source = repo / 'native/Sources/Orbit/Environment'
tests = Path(__file__).resolve().parent
launcher = repo / 'native/OrbitChromium/App/EngineComposition+Chromium.swift'
old_revision = 'f874e602cf383f66bb589d09c9124009067edbef'
flags = ['swiftc', '-swift-version', '6', '-j', '2', '-num-threads', '2',
         '-module-cache-path', str(scratch / 'module-cache')]


def compile_logged(command, name):
    with (scratch / (name + '.log')).open('wb') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)


empty = scratch / 'Empty.swift'
empty.write_text('// Inert modules. No engine implementation.\n')
for module in ['BrowserEngine', 'ChromiumEngine']:
    compile_logged(flags + ['-parse-as-library', '-emit-module', '-module-name', module,
                           '-emit-module-path', str(scratch / (module + '.swiftmodule')), str(empty)], module)
base_sources = [source / name for name in ['OrbitBuildIdentity.swift', 'OrbitProductConfiguration.swift',
                                          'SyntheticDataGuard.swift', 'LaunchConfiguration.swift']]
base_sources += [launcher, tests / 'AuthenticationLauncherIndependentReview.swift']
old_modules = modules
old_core_hashes = {}
if args.compare_old:
    # Compile the entire exact old BrowserCore too: the negative control is not linked
    # against a newer recovery implementation. These are extracted blobs, not a checkout.
    old_modules = scratch / 'old-modules'; old_modules.mkdir()
    old_core = scratch / 'old-core'; old_core.mkdir()
    paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', old_revision,
                                     'native/Sources/BrowserCore'], cwd=repo, text=True).splitlines()
    core_sources = []
    for name in paths:
        if not name.endswith('.swift'): continue
        target = old_core / Path(name).relative_to('native/Sources/BrowserCore')
        target.parent.mkdir(parents=True, exist_ok=True)
        data = subprocess.check_output(['git', 'show', old_revision + ':' + name], cwd=repo)
        target.write_bytes(data); core_sources.append(str(target))
        old_core_hashes[name] = hashlib.sha256(data).hexdigest()
    compile_logged(flags + ['-parse-as-library', '-package-name', 'OrbitLabNative', '-module-name', 'BrowserCore',
                           '-emit-library', '-static', '-emit-module', '-emit-module-path',
                           str(old_modules / 'BrowserCore.swiftmodule')] + core_sources +
                           ['-o', str(old_modules / 'libBrowserCore.a')], 'old-core')
results = []
for revision in ['fixed'] + (['old'] if args.compare_old else []):
    sources = base_sources
    if revision == 'old':
        old_directory = scratch / 'old'
        old_directory.mkdir()
        sources = []
        for path in base_sources:
            target = old_directory / path.name
            target.write_bytes(subprocess.check_output(['git', 'show', old_revision + ':' + str(path.relative_to(repo))], cwd=repo))
            sources.append(target)
    executable = scratch / ('launcher-' + revision)
    linked_modules = old_modules if revision == 'old' else modules
    compile_logged(flags + ['-parse-as-library', '-I', str(linked_modules), '-L', str(linked_modules), '-lBrowserCore',
                           '-I', str(scratch)] + [str(p) for p in sources] + ['-o', str(executable)], revision)
    cases = []
    for case in ['untouched', 'malformed-registration', 'registration-writing', 'symlink-registration',
                 'special-mode-registration', 'foreign-registration']:
        with tempfile.TemporaryDirectory(prefix='orbit-registration-launch-') as temporary:
            home = Path(temporary).resolve()
            root = home / 'root'; root.mkdir(mode=0o700)
            (root / 'Chromium').mkdir(mode=0o700)
            session = root / 'session.json'
            session.write_bytes(b'invented-original-session'); session.chmod(0o600)
            registration = root / '.orbit-auth-root-registration'
            if case == 'registration-writing':
                registration = root / '.orbit-auth-root-registration.writing'
            if case != 'untouched':
                registration.write_bytes(b'invalid-registration-fixture'); registration.chmod(0o600)
            if case == 'symlink-registration':
                saved = home / 'saved'; registration.rename(saved); registration.symlink_to(saved)
            if case == 'special-mode-registration':
                registration.chmod(0o4600)
            if case == 'foreign-registration':
                # Syntactically valid but foreign inode/root/service ownership record.
                registration.write_text(json.dumps({'version': 1, 'registration': '11111111-1111-1111-1111-111111111111',
                    'product': 'daily', 'service': 'Orbit Authentication Recovery v1', 'owner': os.getuid(),
                    'rootDevice': 1, 'rootInode': 1, 'location': '', 'fileDevice': 1, 'fileInode': 1}, sort_keys=True, separators=(',', ':')))
            before = session.read_bytes()
            child = subprocess.Popen([str(executable), '--use-mock-keychain', '--orbit-data-root=' + str(root)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                stdout, stderr = child.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                child.kill(); child.communicate(); raise AssertionError('Owned inert launcher exceeded deadline')
            expected = 64 if revision == 'old' and case == 'symlink-registration' else 0 if revision == 'old' or case == 'untouched' else 65
            assert child.returncode == expected, (revision, case, child.returncode)
            stages = stdout.decode().splitlines()
            if expected == 65:
                assert stages == [], case
                assert stderr == b'orbit: authentication recovery refused before runtime\n', case
            elif expected == 64:
                assert stages == [] and stderr.startswith(b'orbit: '), case
            else:
                assert stages == ['cold-launch-install', 'hook-factory', 'hook-will-start', 'hook-switches',
                                  'hook-hidden', 'runtime-options', 'runtime-shared', 'runtime-run'], case
                assert stderr == b'', case
            assert session.read_bytes() == before, case
            cases.append({'case': case, 'exit': child.returncode, 'allChildrenJoined': True,
                          'runtimeStages': len(stages), 'stateUnchanged': True})
    results.append({'source': revision, 'cases': cases})
evidence = {'actualLauncher': True, 'CEFLinkedOrRun': False, 'applicationCreated': False,
            'systemSecItemOperations': False, 'sourcesSHA256': {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in base_sources},
            'oldRevision': old_revision if args.compare_old else None,
            'exactOldCoreSourceSHA256': old_core_hashes, 'results': results}
(scratch / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
print('PASS actual launcher: five registration regressions refuse before hooks; untouched reaches inert runtime')
if args.compare_old:
    print('CONFIRMED exact old launcher executes every runtime stage for four refused registration cases; its existing synthetic symlink refusal remains')
