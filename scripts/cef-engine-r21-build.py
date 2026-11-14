#!/usr/bin/env python3
"""Build the fork union on the supported CEF 8127 / Chromium 158 milestone (r21).

Run cef-engine-milestone-migrate.py first. The builder refuses any Chromium revision,
VERSION or dependency other than the pins, any CEF tree other than the ported fork, and
a Chromium tree without the complete fork union; it never replaces an r21 distribution.
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
SPEC = importlib.util.spec_from_file_location('engine_build', REPO / 'scripts/cef-engine-extensions-build.py')
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
x2 = build.x2
PATCHES = REPO / 'native/OrbitChromium/cef-patches/engine-r21'
FLAVOR = 'orbit-engine-extensions-r21'
# Must equal CEF_API_VERSION in native/OrbitChromium/CMakeLists.txt (checked by tests).
WRAPPER_API_VERSION = '15600'


def git(root, *command):
    return subprocess.check_output(['git', *command], cwd=root, text=True).strip()


def check_pins(pins):
    if git(x2.SRC, 'rev-parse', 'HEAD') != pins['chromium_commit']:
        raise SystemExit('Run cef-engine-milestone-migrate.py --version %s first' % pins['chromium_tag'])
    version = git(x2.SRC, 'show', 'HEAD:chrome/VERSION')
    if '.'.join(line.split('=', 1)[1] for line in version.split()) != pins['chromium_tag']:
        raise SystemExit('Chromium VERSION does not match the pinned release')
    for name, expected in pins['dependencies'].items():
        if git(x2.SRC / name, 'rev-parse', 'HEAD') != expected:
            raise SystemExit('Dependency revision mismatch: ' + name)
    patch = PATCHES / 'cef.patch'
    if hashlib.sha256(patch.read_bytes()).hexdigest() != pins['cef_patch_sha256']:
        raise SystemExit('CEF patch checksum mismatch')
    if subprocess.run(['git', 'merge-base', '--is-ancestor', pins['cef_base'], 'HEAD'], cwd=x2.CEF_REPO).returncode:
        raise SystemExit('CEF checkout does not descend from the pinned branch head')
    if git(x2.CEF_REPO, 'rev-parse', 'HEAD^{tree}') != pins['cef_tree']:
        raise SystemExit('CEF checkout is not the ported fork union')
    if git(x2.CEF_REPO, 'status', '--porcelain', '--untracked-files=no'):
        raise SystemExit('Uncommitted CEF source changes; commit them to the fork branch first')
    chromium = PATCHES / 'chromium.patch'
    if hashlib.sha256(chromium.read_bytes()).hexdigest() != pins['chromium_patch_sha256']:
        raise SystemExit('Chromium patch checksum mismatch')
    applied = subprocess.run(['git', 'apply', '--reverse', '--check', str(chromium)], cwd=x2.SRC,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not applied:
        raise SystemExit('The Chromium fork union is not applied; rerun the migration or apply chromium.patch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=8)
    parser.add_argument('--logs', type=Path, default=Path('/tmp/orbit-engine-r21/engine'))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    pins = json.loads((PATCHES / 'source.json').read_text())
    with x2.source_tree_lock():
        x2.guard()
        if build.chromium_build_active():
            raise SystemExit('Another Chromium build is active')
        if (x2.DISTRIB / FLAVOR).exists() and not args.dry_run:
            raise SystemExit('Preserve the existing distribution; replacement is refused')
        check_pins(pins)
        source_lab = x2.load(x2.MAIN / 'scripts/chromium-source-lab.py', 'r21_source_lab')
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
        exported.update(chromium_tag=pins['chromium_tag'], chromium_commit=pins['chromium_commit'],
                        cef_base=pins['cef_base'], cef_tree=pins['cef_tree'],
                        cef_patch_sha256=pins['cef_patch_sha256'],
                        chromium_patch_sha256=pins['chromium_patch_sha256'])
        path.write_text(json.dumps(exported, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
