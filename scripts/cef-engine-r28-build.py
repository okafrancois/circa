#!/usr/bin/env python3
"""Build r28: the complete r27/API19 composition on Chromium 158.0.8127.90.

Run cef-engine-security-update.py first. This builder verifies all r27 source pins,
unions and deltas under the shared lock; no patch is added or removed. It exports
a separate distribution and refuses to replace it. Ninja runs at nice 10, at most -j8.
"""
import argparse
from contextlib import redirect_stdout, redirect_stderr
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


r27 = load('engine_r27_build', 'scripts/cef-engine-r27-build.py')
r26 = r27.r26
r25, r24, r22, build, x2 = r26.r25, r26.r24, r26.r22, r26.build, r26.x2
PATCHES = REPO / 'native/OrbitChromium/cef-patches'
FLAVOR = 'orbit-engine-extensions-r28'
# Must equal CEF_API_VERSION in native/OrbitChromium/CMakeLists.txt (checked by tests).
WRAPPER_API_VERSION = r26.WRAPPER_API_VERSION
FRAMEWORK_MARKERS = r27.FRAMEWORK_MARKERS


def check_r27(pins):
    r27.check_r26(pins)
    if r27.delta_states(pins, False) != ('applied', 'applied'):
        raise SystemExit('The complete r27 composition must already be applied')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=8)
    parser.add_argument('--logs', type=Path, default=Path('/tmp/circa-maintenance-2026-11-28/engine'))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    pins = json.loads((PATCHES / 'engine-r28/source.json').read_text())
    with x2.source_tree_lock():
        if build.chromium_build_active():
            raise SystemExit('Another Chromium build is active')
        if (x2.DISTRIB / FLAVOR).exists() and not args.dry_run:
            raise SystemExit('Preserve the existing distribution; replacement is refused')
        check_r27(pins)
        print('pins and complete r27 union: ok', flush=True)
        source_lab = x2.load(x2.MAIN / 'scripts/chromium-source-lab.py', 'r28_source_lab')
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
        check_r27(pins)
        previous = pins['previous_deltas']
        exported.update(chromium_tag=pins['chromium_tag'], chromium_commit=pins['chromium_commit'],
                        cef_base=pins['cef_base'], cef_tree=pins['cef_tree'],
                        cef_patch_sha256=pins['cef_patch_sha256'],
                        chromium_patch_sha256=pins['chromium_patch_sha256'],
                        previous_deltas={'r22': previous['r22']['sha256'], 'r23': previous['r23']['sha256'],
                                         'r24_chromium': previous['r24']['chromium']['sha256'],
                                         'r24_cef': previous['r24']['cef']['sha256'],
                                         'r26_chromium': previous['r26']['sha256'],
                                         'r27_chromium': pins['chromium_delta_patch_sha256'],
                                         'r27_cef': pins['cef_delta_patch_sha256']},
                        chromium_delta_patch_sha256=pins['chromium_delta_patch_sha256'],
                        cef_delta_patch_sha256=pins['cef_delta_patch_sha256'],
                        side_api_version=pins['side_api_version'])
        path.write_text(json.dumps(exported, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
