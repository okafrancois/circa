#!/usr/bin/env python3
"""Export the composed hosted password engine in the existing incremental cache."""
import argparse
from contextlib import redirect_stdout, redirect_stderr
import importlib.util
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('engine_build', REPO / 'scripts/cef-engine-extensions-build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
x2 = build.x2
FLAVOR = 'orbit-engine-extensions-r6'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=8)
    parser.add_argument('--logs', type=Path, default=Path('/tmp/engine-r6-passwords'))
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    with x2.source_tree_lock():
        x2.guard()
        if build.chromium_build_active():
            raise SystemExit('Another Chromium build is active')
        if (x2.DISTRIB / FLAVOR).exists():
            raise SystemExit('Preserve the existing distribution and choose a new flavor')
        if subprocess.check_output(['git', 'status', '--porcelain'], cwd=x2.CEF_REPO).strip():
            raise SystemExit('CEF has uncommitted changes')
        for role, root in [('cef', x2.CEF_REPO), ('chromium', x2.SRC)]:
            patch = REPO / ('native/OrbitChromium/cef-patches/engine-r6/' + role + '.patch')
            composed = subprocess.run(['git', 'apply', '-R', '--check', str(patch)], cwd=root,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if composed.returncode:
                base = REPO / ('native/OrbitChromium/cef-patches/engine-r5/' + role + '.patch')
                present = subprocess.run(['git', 'apply', '-R', '--check', str(base)], cwd=root,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if present.returncode:
                    subprocess.run(['git', 'apply', '--check', str(base)], cwd=root, check=True)
                    subprocess.run(['git', 'apply', str(base)], cwd=root, check=True)
                subprocess.run(['git', 'apply', '--check', str(patch)], cwd=root, check=True)
                subprocess.run(['git', 'apply', str(patch)], cwd=root, check=True)
                if role == 'cef':
                    subprocess.run(['git', 'add', '-A'], cwd=root, check=True)
                    subprocess.run(['git', 'commit', '-m', 'Bridge hosted password decisions'], cwd=root, check=True)
        source_lab = x2.load(REPO / 'scripts/chromium-source-lab.py', 'password_source_lab')
        env = dict(source_lab.ENV, ORBIT_CEF_PATCHES='1', NINJA_STATUS='[%f/%t %es] ')
        env.pop('LIBRARY_PATH', None)
        with (args.logs / 'version.log').open('w') as log:
            subprocess.run(['python3', 'tools/make_version_header.py',
                            str(x2.SRC / build.CODEC_OUT / 'gen/cef/include/cef_version.h')],
                           cwd=x2.CEF_REPO, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        command = ['/usr/bin/sandbox-exec', '-f', str(x2.FORK / 'build-codecs-isolation.sb'),
                   'nice', '-n', '10', str(x2.SRC / 'third_party/ninja/ninja'),
                   '-C', build.CODEC_OUT, '-j', str(args.jobs), 'cef']
        # Regenerate GN first: a dry run otherwise counts only the regeneration step.
        with (args.logs / 'gn-regeneration.log').open('w') as log:
            subprocess.run(command[:-1] + ['build.ninja'], cwd=x2.SRC, env=env,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        dry = subprocess.run(command + ['-n'], cwd=x2.SRC, env=env,
                             capture_output=True, text=True, check=True)
        (args.logs / 'export-dry-run.log').write_text(dry.stdout + dry.stderr)
        tasks = sum(line.startswith('[') for line in dry.stdout.splitlines())
        print('Incremental Ninja tasks:', tasks, flush=True)
        if tasks > 1500:
            raise SystemExit('Broad rebuild detected; estimate duration before proceeding')
        build.build_cef(command, env, args.logs)
        os.environ['CMAKE_BUILD_PARALLEL_LEVEL'] = '4'
        with (args.logs / 'distribution.log').open('w') as log, redirect_stdout(log), redirect_stderr(log):
            x2.distrib(SimpleNamespace(flavor=FLAVOR, replace=False, build_dir_suffix='_GN_arm64_codecs',
                                      incremental_build_completed=True))
        print('Distribution:', x2.DISTRIB / FLAVOR, flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
