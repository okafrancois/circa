#!/usr/bin/env python3
"""Build r22: the complete r21 union plus the owned-directory OSCrypt compatibility patch.

Chromium 158 gives a non-default user data directory a new "v11" key and makes the "v10"
key that earlier engines used unavailable there, so existing cookies could no longer be
decrypted (and the cookie store drops what it cannot decrypt). r22 keeps "v10" readable in
the directory the embedder owns only. Same pins as r21; --apply adds the delta to the
locked shared tree. The builder refuses any other source state and never replaces an r22
distribution.
"""
import argparse
from contextlib import redirect_stdout, redirect_stderr
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('engine_build', REPO / 'scripts/cef-engine-extensions-build.py')
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
x2 = build.x2
UNION = REPO / 'native/OrbitChromium/cef-patches/engine-r21'
PATCHES = REPO / 'native/OrbitChromium/cef-patches/engine-r22'
FLAVOR = 'orbit-engine-extensions-r22'
# Must equal CEF_API_VERSION in native/OrbitChromium/CMakeLists.txt (checked by tests).
WRAPPER_API_VERSION = '15600'
# The delta recompiles one browser file and relinks the framework. A build of at most this
# many Ninja edges may start with 42 GiB free, above the build loop's own 40 GiB stop; any
# larger build keeps the full start guard.
DELTA_MAX_EDGES = 400
DELTA_FREE_GIB = 42


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
    patch = UNION / 'cef.patch'
    if hashlib.sha256(patch.read_bytes()).hexdigest() != pins['cef_patch_sha256']:
        raise SystemExit('CEF patch checksum mismatch')
    if subprocess.run(['git', 'merge-base', '--is-ancestor', pins['cef_base'], 'HEAD'], cwd=x2.CEF_REPO).returncode:
        raise SystemExit('CEF checkout does not descend from the pinned branch head')
    if git(x2.CEF_REPO, 'rev-parse', 'HEAD^{tree}') != pins['cef_tree']:
        raise SystemExit('CEF checkout is not the ported fork union')
    if git(x2.CEF_REPO, 'status', '--porcelain', '--untracked-files=no'):
        raise SystemExit('Uncommitted CEF source changes; commit them to the fork branch first')
    chromium = UNION / 'chromium.patch'
    if hashlib.sha256(chromium.read_bytes()).hexdigest() != pins['chromium_patch_sha256']:
        raise SystemExit('Chromium patch checksum mismatch')
    applied = subprocess.run(['git', 'apply', '--reverse', '--check', str(chromium)], cwd=x2.SRC,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not applied:
        raise SystemExit('The r21 Chromium fork union is not applied; rerun the migration or apply chromium.patch')


def delta_state(pins, apply):
    delta = PATCHES / pins['delta_patch']
    if hashlib.sha256(delta.read_bytes()).hexdigest() != pins['delta_patch_sha256']:
        raise SystemExit('Delta patch checksum mismatch')
    def check(*flags):
        return subprocess.run(['git', 'apply', '--check', *flags, str(delta)], cwd=x2.SRC,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if check('--reverse'):
        return 'applied'
    if not check():
        raise SystemExit('The OSCrypt delta neither applies nor is applied')
    if not apply:
        return 'not-applied'
    subprocess.run(['git', 'apply', str(delta)], cwd=x2.SRC, check=True)
    return 'applied-now'


def delta_guard():
    free = shutil.disk_usage(x2.FORK).free / 2**30
    if free < DELTA_FREE_GIB:
        raise SystemExit('Free space %.1f GiB below the %d GiB delta guard' % (free, DELTA_FREE_GIB))
    return round(free, 1)


def start_guard(dry_output):
    totals = re.findall(r'^\[[0-9]+/([0-9]+) ', dry_output, re.M)
    edges = int(totals[-1]) if totals else 0
    if edges <= DELTA_MAX_EDGES:
        # The distribution export copies one framework (under 1 GiB): same guard.
        x2.guard = delta_guard
        return edges, delta_guard()
    return edges, x2.guard()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=8)
    parser.add_argument('--logs', type=Path, default=Path('/tmp/orbit-engine-r22/engine'))
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--apply', action='store_true', help='Apply the OSCrypt delta to the locked shared tree')
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    pins = json.loads((PATCHES / 'source.json').read_text())
    with x2.source_tree_lock():
        if build.chromium_build_active():
            raise SystemExit('Another Chromium build is active')
        if (x2.DISTRIB / FLAVOR).exists() and not args.dry_run:
            raise SystemExit('Preserve the existing distribution; replacement is refused')
        check_pins(pins)
        delta = delta_state(pins, args.apply and not args.dry_run)
        print('delta:', delta, flush=True)
        if delta == 'not-applied' and not args.dry_run:
            raise SystemExit('The OSCrypt delta is not applied; rerun with --apply')
        source_lab = x2.load(x2.MAIN / 'scripts/chromium-source-lab.py', 'r22_source_lab')
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
        print('edges %d, free %.1f GiB' % start_guard(dry.stdout), flush=True)
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
                        chromium_patch_sha256=pins['chromium_patch_sha256'],
                        delta_patch_sha256=pins['delta_patch_sha256'])
        path.write_text(json.dumps(exported, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
