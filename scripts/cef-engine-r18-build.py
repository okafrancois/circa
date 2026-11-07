#!/usr/bin/env python3
"""Build the additive native-window engine in the preserved security cache."""
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
SPEC = importlib.util.spec_from_file_location('engine_build', REPO / 'scripts/cef-engine-extensions-build.py')
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
x2 = build.x2
PATCHES = REPO / 'native/OrbitChromium/cef-patches/engine-r18'
FLAVOR = 'orbit-engine-extensions-r18'


def verify_or_apply(root, patch):
    reverse = subprocess.run(['git', 'apply', '--reverse', '--check', str(patch)], cwd=root,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if reverse.returncode:
        subprocess.run(['git', 'apply', '--check', str(patch)], cwd=root, check=True)
        subprocess.run(['git', 'apply', str(patch)], cwd=root, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=8)
    parser.add_argument('--logs', type=Path, default=Path('/tmp/engine-r18'))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    with x2.source_tree_lock():
        x2.guard()
        if build.chromium_build_active():
            raise SystemExit('Another Chromium build is active')
        if (x2.DISTRIB / FLAVOR).exists() and not args.dry_run:
            raise SystemExit('Preserve the existing distribution; replacement is refused')
        pins = json.loads((PATCHES / 'source.json').read_text())
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=x2.SRC, text=True).strip()
        if head != pins['chromium_commit']:
            raise SystemExit('Prepare the pinned security baseline first')
        for name, expected in pins['dependencies'].items():
            actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=x2.SRC / name, text=True).strip()
            if actual != expected:
                raise SystemExit('Security dependency revision mismatch: ' + name)
        subprocess.run(['git', 'merge-base', '--is-ancestor', pins['cef_parent_commit'], 'HEAD'],
                       cwd=x2.CEF_REPO, check=True)
        popup = REPO / 'native/OrbitChromium/cef-patches/popup-cancellation-r1/chromium.patch'
        verify_or_apply(x2.SRC, popup)
        for role, root in [('cef', x2.CEF_REPO), ('chromium', x2.SRC)]:
            patch = PATCHES / (role + '.patch')
            if hashlib.sha256(patch.read_bytes()).hexdigest() != pins[role + '_patch_sha256']:
                raise SystemExit('Patch checksum mismatch: ' + role)
            verify_or_apply(root, patch)
        source_lab = x2.load(x2.MAIN / 'scripts/chromium-source-lab.py', 'native_window_source_lab')
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
        dry = subprocess.run(command + ['-n'], cwd=x2.SRC, env=env,
                             capture_output=True, text=True, check=True)
        (args.logs / 'dry-run.log').write_text(dry.stdout + dry.stderr)
        print(dry.stdout, flush=True)
        if args.dry_run:
            return 0
        build.build_cef(command, env, args.logs)
        os.environ['CMAKE_BUILD_PARALLEL_LEVEL'] = '4'
        x2.PATCHED_FLAVORS += (FLAVOR,)
        with (args.logs / 'distribution.log').open('w') as log, redirect_stdout(log), redirect_stderr(log):
            x2.distrib(SimpleNamespace(flavor=FLAVOR, replace=False, build_dir_suffix='_GN_arm64_codecs',
                                      incremental_build_completed=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
