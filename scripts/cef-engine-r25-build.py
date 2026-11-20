#!/usr/bin/env python3
"""Build r25: the complete r24 composition on the 158.0.8127.65 release of branch 8127.

No new delta: the r21 unions, the r22 and r23 deltas and both r24 deltas are carried
unchanged by scripts/cef-engine-security-update.py, which rolls the shared source tree and
its changed dependencies and 3-way merges every working change. Side API stays v19.

The builder refuses any other source state (wrong tag or dependency revision, an unapplied
patch, a merge conflict left by the roll, an uncommitted CEF change outside the r24 delta)
and never replaces an r25 distribution.
"""
import argparse
from contextlib import redirect_stdout, redirect_stderr
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


r24 = load('engine_r24_build', 'scripts/cef-engine-r24-build.py')
r22, build, x2 = r24.r22, r24.build, r24.x2
PATCHES = REPO / 'native/OrbitChromium/cef-patches'
FLAVOR = 'orbit-engine-extensions-r25'
# Must equal CEF_API_VERSION in native/OrbitChromium/CMakeLists.txt (checked by tests).
WRAPPER_API_VERSION = r24.WRAPPER_API_VERSION
FRAMEWORK_MARKERS = r24.FRAMEWORK_MARKERS


def git(root, *command):
    return subprocess.check_output(['git', *command], cwd=root, text=True).strip()


def check_pins(pins):
    if git(x2.SRC, 'rev-parse', 'HEAD') != pins['chromium_commit']:
        raise SystemExit('Run cef-engine-security-update.py --version %s first' % pins['chromium_tag'])
    version = git(x2.SRC, 'show', 'HEAD:chrome/VERSION')
    if '.'.join(line.split('=', 1)[1] for line in version.split()) != pins['chromium_tag']:
        raise SystemExit('Chromium VERSION does not match the pinned security release')
    for name, expected in pins['dependencies'].items():
        if git(x2.SRC / name, 'rev-parse', 'HEAD') != expected:
            raise SystemExit('Dependency revision mismatch: ' + name)
    # Only files with working changes that the roll also changed went through a 3-way merge.
    changed = set(git(x2.SRC, 'diff', '--name-only', pins['previous_chromium_commit'], 'HEAD').split())
    modified = set(git(x2.SRC, 'diff', '--name-only', 'HEAD').split())
    for name in sorted(changed & modified):
        text = (x2.SRC / name).read_text(errors='replace')
        if any(line.startswith(('<<<<<<< ', '>>>>>>> ')) for line in text.splitlines()):
            raise SystemExit('Resolve the source merge conflict in ' + name)
    for name in pins['dependencies']:
        if git(x2.SRC / name, 'diff', '--name-only', '--diff-filter=U'):
            raise SystemExit('Resolve the source merge conflict in ' + name)
    for name in ('cef', 'chromium'):
        if hashlib.sha256((PATCHES / 'engine-r21' / (name + '.patch')).read_bytes()).hexdigest() \
                != pins[name + '_patch_sha256']:
            raise SystemExit('r21 %s union checksum mismatch' % name)
    if git(x2.CEF_REPO, 'rev-parse', 'HEAD^{tree}') != pins['cef_tree']:
        raise SystemExit('CEF checkout is not the ported fork union')
    previous = pins['previous_deltas']
    cef_delta = previous['r24']['cef']
    allowed = set(r24.patch_files(PATCHES / cef_delta['patch']))
    changed = {line.split(maxsplit=1)[1] for line in
               git(x2.CEF_REPO, 'status', '--porcelain', '--untracked-files=no').splitlines()}
    if changed - allowed:
        raise SystemExit('Uncommitted CEF changes outside the r24 delta: ' + ', '.join(sorted(changed - allowed)))
    union = PATCHES / 'engine-r21/chromium.patch'
    if subprocess.run(['git', 'apply', '--reverse', '--check', str(union)], cwd=x2.SRC,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise SystemExit('The r21 Chromium fork union is not applied')
    deltas = [('r22', previous['r22'], x2.SRC), ('r23', previous['r23'], x2.SRC),
              ('r24 Chromium', previous['r24']['chromium'], x2.SRC), ('r24 CEF', cef_delta, x2.CEF_REPO)]
    for label, delta, root in deltas:
        if r24.patch_state(PATCHES / delta['patch'], delta['sha256'], root, False, label) != 'applied':
            raise SystemExit('The %s delta is not applied on the rolled tree' % label)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=8)
    parser.add_argument('--logs', type=Path, default=Path('/tmp/ENGINE-R25/engine'))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    pins = json.loads((PATCHES / 'engine-r25/source.json').read_text())
    with x2.source_tree_lock():
        if build.chromium_build_active():
            raise SystemExit('Another Chromium build is active')
        if (x2.DISTRIB / FLAVOR).exists() and not args.dry_run:
            raise SystemExit('Preserve the existing distribution; replacement is refused')
        check_pins(pins)
        print('pins and union: ok', flush=True)
        source_lab = x2.load(x2.MAIN / 'scripts/chromium-source-lab.py', 'r25_source_lab')
        env = dict(source_lab.ENV, ORBIT_CEF_PATCHES='1', NINJA_STATUS='[%f/%t %es] ')
        env.pop('LIBRARY_PATH', None)
        env['PATH'] = str(Path(sys.executable).resolve().parent) + os.pathsep + env['PATH']
        with (args.logs / 'version.log').open('w') as log:
            subprocess.run([sys.executable, 'tools/make_version_header.py',
                            str(x2.SRC / build.CODEC_OUT / 'gen/cef/include/cef_version.h')],
                           cwd=x2.CEF_REPO, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        command = ['/usr/bin/sandbox-exec', '-f', str(x2.FORK / 'build-codecs-isolation.sb'),
                   'nice', '-n', '10', str(x2.SRC / 'third_party/ninja/ninja'),
                   '-C', build.CODEC_OUT, '-j', str(args.jobs), 'cef']
        dry = subprocess.run(command + ['-n'], cwd=x2.SRC, env=env, capture_output=True, text=True, check=True)
        (args.logs / 'dry-run.log').write_text(dry.stdout + dry.stderr)
        print(dry.stdout.splitlines()[-1] if dry.stdout else '', flush=True)
        print('edges %d, free %.1f GiB' % r22.start_guard(dry.stdout), flush=True)
        if args.dry_run:
            return 0
        build.build_cef(command, env, args.logs)
        os.environ['CMAKE_BUILD_PARALLEL_LEVEL'] = '4'
        with (args.logs / 'distribution.log').open('w') as log, redirect_stdout(log), redirect_stderr(log):
            x2.distrib(SimpleNamespace(flavor=FLAVOR, replace=False, build_dir_suffix='_GN_arm64_codecs',
                                      incremental_build_completed=True,
                                      wrapper_api_version=WRAPPER_API_VERSION))
        path = x2.DISTRIB / FLAVOR / 'manifest.json'
        exported = json.loads(path.read_text())
        framework = Path(exported['root']) / 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'
        binary = framework.read_bytes()
        for marker in FRAMEWORK_MARKERS + (pins['webauthn_keychain_access_group'].encode(),
                                           pins['chromium_tag'].encode()):
            if marker not in binary:
                raise SystemExit('The exported framework lacks %r' % marker.decode())
        previous = pins['previous_deltas']
        exported.update(chromium_tag=pins['chromium_tag'], chromium_commit=pins['chromium_commit'],
                        cef_base=pins['cef_base'], cef_tree=pins['cef_tree'],
                        cef_patch_sha256=pins['cef_patch_sha256'],
                        chromium_patch_sha256=pins['chromium_patch_sha256'],
                        previous_deltas={'r22': previous['r22']['sha256'], 'r23': previous['r23']['sha256']},
                        chromium_delta_patch_sha256=previous['r24']['chromium']['sha256'],
                        cef_delta_patch_sha256=previous['r24']['cef']['sha256'],
                        side_api_version=pins['side_api_version'])
        path.write_text(json.dumps(exported, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
