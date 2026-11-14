#!/usr/bin/env python3
"""Build r23: the complete r22 composition plus the system passkeys patch.

The platform (Touch ID) authenticator uses the keychain access group of the signed browser
instead of the default Chromium one, and a WebContents hosted directly in the embedder's
AppKit views (no Views widget) gives the system passkey provider the NSWindow that contains
it. Same pins as r22 and no side API change; --apply adds the delta to the locked shared
tree. The builder refuses any other source state and never replaces an r23 distribution.
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


r22 = load('engine_r22_build', 'scripts/cef-engine-r22-build.py')
build, x2 = r22.build, r22.x2
PATCHES = REPO / 'native/OrbitChromium/cef-patches'
FLAVOR = 'orbit-engine-extensions-r23'
# Must equal CEF_API_VERSION in native/OrbitChromium/CMakeLists.txt (checked by tests).
WRAPPER_API_VERSION = '15600'


def patch_state(path, expected_sha256, apply, label):
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected_sha256:
        raise SystemExit(label + ' patch checksum mismatch')
    def check(*flags):
        return subprocess.run(['git', 'apply', '--check', *flags, str(path)], cwd=x2.SRC,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if check('--reverse'):
        return 'applied'
    if not check():
        raise SystemExit('The %s patch neither applies nor is applied' % label)
    if not apply:
        return 'not-applied'
    subprocess.run(['git', 'apply', str(path)], cwd=x2.SRC, check=True)
    return 'applied-now'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=8)
    parser.add_argument('--logs', type=Path, default=Path('/tmp/orbit-engine-r23/engine'))
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--apply', action='store_true', help='Apply the passkeys delta to the locked shared tree')
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    pins = json.loads((PATCHES / 'engine-r23/source.json').read_text())
    with x2.source_tree_lock():
        if build.chromium_build_active():
            raise SystemExit('Another Chromium build is active')
        if (x2.DISTRIB / FLAVOR).exists() and not args.dry_run:
            raise SystemExit('Preserve the existing distribution; replacement is refused')
        r22.check_pins(pins)
        previous = patch_state(PATCHES / pins['previous_delta_patch'], pins['previous_delta_patch_sha256'],
                               False, 'r22 OSCrypt')
        if previous != 'applied':
            raise SystemExit('The r22 delta is not applied; build r22 first')
        delta = patch_state(PATCHES / 'engine-r23' / pins['delta_patch'], pins['delta_patch_sha256'],
                            args.apply and not args.dry_run, 'passkeys')
        print('delta:', delta, flush=True)
        if delta == 'not-applied' and not args.dry_run:
            raise SystemExit('The passkeys delta is not applied; rerun with --apply')
        source_lab = x2.load(x2.MAIN / 'scripts/chromium-source-lab.py', 'r23_source_lab')
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
        group = pins['webauthn_keychain_access_group'].encode()
        if b'\0' + group + b'\0' not in framework.read_bytes():
            raise SystemExit('The exported framework does not contain the keychain access group')
        exported.update(chromium_tag=pins['chromium_tag'], chromium_commit=pins['chromium_commit'],
                        cef_base=pins['cef_base'], cef_tree=pins['cef_tree'],
                        cef_patch_sha256=pins['cef_patch_sha256'],
                        chromium_patch_sha256=pins['chromium_patch_sha256'],
                        previous_delta_patch_sha256=pins['previous_delta_patch_sha256'],
                        delta_patch_sha256=pins['delta_patch_sha256'])
        path.write_text(json.dumps(exported, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
