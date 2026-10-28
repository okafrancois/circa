#!/usr/bin/env python3
"""Build the product extension union in the existing, locked Chromium tree."""
import argparse
import importlib.util
from datetime import datetime, timezone
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('x2', REPO / 'scripts/orbit-chromium-x2.py')
x2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(x2)
PATCHES = REPO / 'native/OrbitChromium/cef-patches/engine-extensions-r1'
FLAVOR = 'orbit-engine-extensions'
LOGS = REPO / 'artifacts/engine-extensions/cef-build'
NOTIFICATION_FLAVOR = 'orbit-engine-extensions-r2'
CODEC_FLAVOR = 'orbit-engine-extensions-r3'
CODEC_OUT = 'out/Release_GN_arm64_codecs'


def run(*command, cwd=None, **kwargs):
    return subprocess.run(command, cwd=cwd, check=True, **kwargs)


def chromium_build_active():
    processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm=,args='], text=True)
    for line in processes.splitlines():
        fields = line.split(None, 2)
        if len(fields) < 3 or Path(fields[1]).name not in ('ninja', 'autoninja', 'siso'):
            continue
        if str(x2.FORK) in fields[1] + fields[2]:
            return True
        cwd = subprocess.run(['/usr/sbin/lsof', '-a', '-p', fields[0], '-d', 'cwd', '-Fn'],
                             capture_output=True, text=True, timeout=5)
        if any(row.startswith('n' + str(x2.SRC)) for row in cwd.stdout.splitlines()):
            return True
    return False


def compose_notifications(logs):
    patches = REPO / 'native/OrbitChromium/cef-patches/share-notify-r1'
    roots = [('cef', x2.CEF_REPO), ('chromium', x2.SRC)]
    pending = []
    for role, root in roots:
        patch = patches / (role + '.patch')
        check = subprocess.run(['git', 'apply', '--check', str(patch)], cwd=root,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if check.returncode:
            run('git', 'apply', '-R', '--check', str(patch), cwd=root)
        else:
            pending.append((role, root, patch))
    current = subprocess.check_output(['git', 'branch', '--show-current'], cwd=x2.CEF_REPO, text=True).strip()
    if current == 'orbit/engine-extensions':
        run('git', 'switch', '-c', 'orbit/engine-extensions-r2', cwd=x2.CEF_REPO)
    elif current != 'orbit/engine-extensions-r2':
        raise SystemExit('Notifications require the compiled engine-extensions union')
    for role, root, patch in pending:
        names = [line[6:] for line in patch.read_text().splitlines() if line.startswith('+++ b/')]
        for name in names:
            source = root / name
            if source.is_file():
                target = logs / 'before' / role / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        run('git', 'apply', str(patch), cwd=root)
        if role == 'cef':
            run('git', 'add', *names, cwd=root)
            run('git', 'commit', '-m', 'Route native notification clicks to the owning CEF surface', cwd=root)


def build_cef(command, env, logs):
    with (logs / 'ninja.log').open('ab') as stream:
        process = subprocess.Popen(command, cwd=x2.SRC, env=env, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while process.poll() is None:
                if shutil.disk_usage(x2.FORK).free < 40 * 2**30:
                    raise RuntimeError('Stopping CEF build to preserve 40 GiB of free disk space')
                time.sleep(10)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, command)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--existing-union', action='store_true',
                        help='Rebuild the already composed product union without reapplying source patches')
    parser.add_argument('--notifications', action='store_true',
                        help='Add share-notify-r1 and create the separate engine-extensions-r2 distribution')
    parser.add_argument('--codecs', action='store_true',
                        help='Build the notification union with H.264/AAC as the separate r3 distribution')
    parser.add_argument('--jobs', type=int, choices=range(1, 7), default=6)
    args = parser.parse_args()
    if args.notifications and not args.existing_union:
        parser.error('--notifications requires --existing-union')
    if args.codecs and not (args.existing_union and args.notifications):
        parser.error('--codecs requires --existing-union --notifications')
    flavor = CODEC_FLAVOR if args.codecs else NOTIFICATION_FLAVOR if args.notifications else FLAVOR
    logs = (REPO / 'artifacts/engine-codecs/cef-build' if args.codecs else
            REPO / 'artifacts/engine-notifications/cef-build' if args.notifications else LOGS)
    logs.mkdir(parents=True, exist_ok=True)
    with x2.source_tree_lock():
        x2.guard()
        if chromium_build_active():
            raise SystemExit('Another build is active; wait before running this command again')
        if subprocess.check_output(['git', 'status', '--porcelain'], cwd=x2.CEF_REPO).strip():
            raise SystemExit('CEF has uncommitted changes; preserve and inspect them first')
        # Keep the retained R4 candidate as an ancestor. The checked patch composes
        # modal hosts, v4, unowned tabs and native installer transfer routing.
        roots = [('cef', x2.CEF_REPO, 'cef.patch'), ('chromium', x2.SRC, 'chromium.patch')]
        roots.extend([
            ('cef', x2.CEF_REPO, 'toolbar.patch'),
            ('chromium', x2.SRC, 'post-install-dismiss.patch'),
            ('chromium', x2.SRC, 'post-install-host.patch'),
            ('chromium', x2.SRC, 'popup-anchor.patch'),
        ])
        if args.existing_union:
            current = subprocess.check_output(['git', 'branch', '--show-current'], cwd=x2.CEF_REPO, text=True).strip()
            allowed = ('orbit/engine-extensions', 'orbit/engine-extensions-r2') if args.notifications else ('orbit/engine-extensions',)
            if current not in allowed:
                raise SystemExit('The existing compiled product union branch is required')
            roots = []
        if args.notifications:
            if (x2.DISTRIB / flavor).exists():
                raise SystemExit('The notifications distribution already exists; preserve it before rebuilding')
            compose_notifications(logs)
        cef_branch_created = False
        for role, root, patch_name in roots:
            patch = PATCHES / patch_name
            result = subprocess.run(['git', 'apply', '--check', str(patch)], cwd=root,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode:
                run('git', 'apply', '-R', '--check', str(patch), cwd=root)
            else:
                # A practical backup for restoration; no unrelated files are copied or reset.
                names = [line[6:] for line in patch.read_text().splitlines() if line.startswith('+++ b/')]
                for name in names:
                    source = root / name
                    if source.is_file():
                        target = logs / 'before' / patch_name / role / name
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(source, target)
                if role == 'cef' and not cef_branch_created:
                    branch = 'orbit/' + flavor.removeprefix('orbit-')
                    current = subprocess.check_output(['git', 'branch', '--show-current'], cwd=root, text=True).strip()
                    if current != branch:
                        run('git', 'switch', '-c', branch, cwd=root)
                    cef_branch_created = True
                run('git', 'apply', str(patch), cwd=root)
                if role == 'cef':
                    run('git', 'add', *names, cwd=root)
                    run('git', 'commit', '-m', 'Compose product extension engine and native install hosts', cwd=root)
        source_lab = x2.load(x2.MAIN / 'scripts/chromium-source-lab.py', 'extension_source_lab')
        env = dict(source_lab.ENV, ORBIT_CEF_PATCHES='1', NINJA_STATUS='[%f/%t %es] ',
                   CMAKE_BUILD_PARALLEL_LEVEL='4')
        output = x2.OUT
        if args.codecs:
            output = CODEC_OUT
            config = x2.SRC / output / 'args.gn'
            config.parent.mkdir(parents=True, exist_ok=True)
            if config.exists():
                shutil.copy2(config, logs / 'args.gn.before')
            # Keep all product CEF options, including its CDM configuration. CEF
            # consumes these GN flags directly; no separate CEF codec flag exists.
            options = (x2.SRC / x2.OUT / 'args.gn').read_text().splitlines()
            options = [line for line in options if line.split('=', 1)[0].strip()
                       not in ('proprietary_codecs', 'ffmpeg_branding')]
            config.write_text('\n'.join(options) + '\nproprietary_codecs=true\nffmpeg_branding="Chrome"\n')
            with (logs / 'gn.log').open('w') as stream:
                run(str(x2.SRC / 'buildtools/mac/gn'), 'gen', output, cwd=x2.SRC, env=env,
                    stdout=stream, stderr=subprocess.STDOUT)
                # Git HEAD is not a Ninja input. Refresh cached version metadata
                # explicitly before compiling this newer CEF source union.
                run(sys.executable, 'tools/make_version_header.py',
                    str(x2.SRC / output / 'gen/cef/include/cef_version.h'),
                    cwd=x2.CEF_REPO, env=env, stdout=stream, stderr=subprocess.STDOUT)
        command = ['/usr/bin/sandbox-exec', '-f', str(x2.FORK / 'build-isolation.sb'),
                   'nice', '-n', '10', str(x2.FORK / 'depot_tools/autoninja'),
                   '-C', output, '-j', str(args.jobs), 'cef']
        print('Building:', ' '.join(command), flush=True)
        build_cef(command, env, logs)
        # Reuse the distributor and wrapper build. The full prerequisite-ledger
        # snapshots of the older runner have no effect on the linked framework.
        x2.PATCHED_FLAVORS += (flavor,)
        previous_parallelism = os.environ.get('CMAKE_BUILD_PARALLEL_LEVEL')
        os.environ['CMAKE_BUILD_PARALLEL_LEVEL'] = '4'
        try:
            target = x2.DISTRIB / flavor
            if target.exists():
                stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
                target.rename(target.with_name(flavor + '-previous-' + stamp))
            with (logs / 'distribution.log').open('a') as stream:
                import contextlib
                with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
                    x2.distrib(SimpleNamespace(flavor=flavor, replace=False,
                                              build_dir_suffix='_GN_arm64_codecs' if args.codecs else None))
        finally:
            if previous_parallelism is None:
                os.environ.pop('CMAKE_BUILD_PARALLEL_LEVEL', None)
            else:
                os.environ['CMAKE_BUILD_PARALLEL_LEVEL'] = previous_parallelism
        print('Distribution:', x2.DISTRIB / flavor, flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
