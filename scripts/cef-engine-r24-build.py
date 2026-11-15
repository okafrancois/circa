#!/usr/bin/env python3
"""Build r24: the complete r23 composition plus side API v19.

v19 adds a detached extension action popup (an engine-owned titled window, no anchor), a
per-tab output volume, and browser-side configuration of the built-in content blocker, which
the engine loads as a component extension of every regular profile. Two generic fixes ride
along: off-the-record contexts create their extension service worker task queue when they are
created, and the cookies event router observes every off-the-record context.

Same pins as r21-r23. The Chromium delta applies to the shared source tree and the CEF delta
to its CEF checkout (left uncommitted on the fork union, as the Chromium deltas are). --apply
adds both under the shared source lock; the builder refuses any other source state and never
replaces an r24 distribution.
"""
import argparse
from contextlib import redirect_stdout, redirect_stderr
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


r22 = load('engine_r22_build', 'scripts/cef-engine-r22-build.py')
build, x2 = r22.build, r22.x2
PATCHES = REPO / 'native/OrbitChromium/cef-patches'
FLAVOR = 'orbit-engine-extensions-r24'
# Must equal CEF_API_VERSION in native/OrbitChromium/CMakeLists.txt (checked by tests).
WRAPPER_API_VERSION = '15600'
# Present in the exported framework only when the v19 sources were compiled in.
FRAMEWORK_MARKERS = (b'orbit-component-extension', b'OrbitDetachedExtensionPopup')


def git(root, *command):
    return subprocess.check_output(['git', *command], cwd=root, text=True).strip()


def patch_files(patch):
    return re.findall(r'^\+\+\+ b/(\S+)', patch.read_text(), re.M)


def patch_state(path, expected_sha256, root, apply, label):
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected_sha256:
        raise SystemExit(label + ' patch checksum mismatch')
    def check(*flags):
        return subprocess.run(['git', 'apply', '--check', *flags, str(path)], cwd=root,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if check('--reverse'):
        return 'applied'
    if not check():
        raise SystemExit('The %s patch neither applies nor is applied' % label)
    if not apply:
        return 'not-applied'
    subprocess.run(['git', 'apply', str(path)], cwd=root, check=True)
    return 'applied-now'


def check_pins(pins):
    """The r21 pins and union, with the CEF delta as the only uncommitted CEF change."""
    if git(x2.SRC, 'rev-parse', 'HEAD') != pins['chromium_commit']:
        raise SystemExit('Run cef-engine-milestone-migrate.py --version %s first' % pins['chromium_tag'])
    for name, expected in pins['dependencies'].items():
        if git(x2.SRC / name, 'rev-parse', 'HEAD') != expected:
            raise SystemExit('Dependency revision mismatch: ' + name)
    for name in ('cef', 'chromium'):
        data = (PATCHES / 'engine-r21' / (name + '.patch')).read_bytes()
        if hashlib.sha256(data).hexdigest() != pins[name + '_patch_sha256']:
            raise SystemExit('r21 %s union checksum mismatch' % name)
    if git(x2.CEF_REPO, 'rev-parse', 'HEAD^{tree}') != pins['cef_tree']:
        raise SystemExit('CEF checkout is not the ported fork union')
    allowed = set(patch_files(PATCHES / 'engine-r24' / pins['cef_delta_patch']))
    changed = {line.split(maxsplit=1)[1] for line in
               git(x2.CEF_REPO, 'status', '--porcelain', '--untracked-files=no').splitlines()}
    if changed - allowed:
        raise SystemExit('Uncommitted CEF changes outside the r24 delta: ' + ', '.join(sorted(changed - allowed)))
    union = PATCHES / 'engine-r21/chromium.patch'
    if subprocess.run(['git', 'apply', '--reverse', '--check', str(union)], cwd=x2.SRC,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise SystemExit('The r21 Chromium fork union is not applied')
    for key in ('r22', 'r23'):
        delta = pins['previous_deltas'][key]
        if patch_state(PATCHES / delta['patch'], delta['sha256'], x2.SRC, False, key) != 'applied':
            raise SystemExit('The %s delta is not applied; build %s first' % (key, key))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=8)
    parser.add_argument('--logs', type=Path, default=Path('/tmp/ENGINE-R24/engine'))
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--apply', action='store_true', help='Apply the r24 deltas to the locked shared tree')
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    pins = json.loads((PATCHES / 'engine-r24/source.json').read_text())
    with x2.source_tree_lock():
        if build.chromium_build_active():
            raise SystemExit('Another Chromium build is active')
        if (x2.DISTRIB / FLAVOR).exists() and not args.dry_run:
            raise SystemExit('Preserve the existing distribution; replacement is refused')
        check_pins(pins)
        apply = args.apply and not args.dry_run
        states = {
            'chromium': patch_state(PATCHES / 'engine-r24' / pins['chromium_delta_patch'],
                                    pins['chromium_delta_patch_sha256'], x2.SRC, apply, 'r24 Chromium'),
            'cef': patch_state(PATCHES / 'engine-r24' / pins['cef_delta_patch'],
                               pins['cef_delta_patch_sha256'], x2.CEF_REPO, apply, 'r24 CEF'),
        }
        print('deltas:', states, flush=True)
        if 'not-applied' in states.values() and not args.dry_run:
            raise SystemExit('The r24 deltas are not applied; rerun with --apply')
        source_lab = x2.load(x2.MAIN / 'scripts/chromium-source-lab.py', 'r24_source_lab')
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
        for marker in FRAMEWORK_MARKERS + (pins['webauthn_keychain_access_group'].encode(),):
            if marker not in binary:
                raise SystemExit('The exported framework lacks %r' % marker.decode())
        exported.update(chromium_tag=pins['chromium_tag'], chromium_commit=pins['chromium_commit'],
                        cef_base=pins['cef_base'], cef_tree=pins['cef_tree'],
                        cef_patch_sha256=pins['cef_patch_sha256'],
                        chromium_patch_sha256=pins['chromium_patch_sha256'],
                        previous_deltas={key: value['sha256'] for key, value in pins['previous_deltas'].items()},
                        chromium_delta_patch_sha256=pins['chromium_delta_patch_sha256'],
                        cef_delta_patch_sha256=pins['cef_delta_patch_sha256'],
                        side_api_version=pins['side_api_version'])
        path.write_text(json.dumps(exported, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
