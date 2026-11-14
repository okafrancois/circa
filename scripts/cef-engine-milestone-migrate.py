#!/usr/bin/env python3
"""Move the owned Chromium/CEF source laboratory to a new milestone branch.

Backs up every working diff and untracked patch output of Chromium and its dependencies
first, then clears only patch outputs, pins depot_tools, synchronizes DEPS to the release
tag, checks out the given CEF commit (the ported fork union) and regenerates the codec
build graph with the fork patches enabled. Patch failures are reported, never forced.
The existing output directory is rebuilt in place by the versioned engine build driver.
"""
import argparse
import ast
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('milestone_engine_build', REPO / 'scripts/cef-engine-extensions-build.py')
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
x2 = build.x2
CHROMIUM_ORIGIN = 'https://chromium.googlesource.com/chromium/src.git'
DEPOT_ORIGIN = 'https://chromium.googlesource.com/chromium/tools/depot_tools.git'
CODEC_DEFINES = ('is_official_build=true is_component_build=false use_remoteexec=false use_siso=false '
                 'target_cpu="arm64" symbol_level=0 chrome_pgo_phase=0 proprietary_codecs=true '
                 'ffmpeg_branding="Chrome"')


def output(root, *command, env=None):
    return subprocess.check_output(command, cwd=root, text=True, env=env).strip()


def entries():
    source = (x2.FORK / 'chromium/.gclient_entries').read_text()
    return ast.literal_eval(ast.parse(source).body[0].value)


def backup(logs):
    """Record every modified repository; nothing is changed here."""
    base = x2.FORK / 'chromium'
    (logs / 'gclient_entries').write_text((base / '.gclient_entries').read_text())
    ledger = []
    for name in ['src'] + [n for n in entries() if n != 'src']:
        root = base / name
        if not (root / '.git').exists():
            continue
        status = output(root, 'git', 'status', '--porcelain').splitlines()
        tracked = [line for line in status if not line.startswith('??')]
        untracked = [line[3:] for line in status if line.startswith('??') and line[3:] != 'cef/']
        if not tracked and not untracked:
            continue
        key = name.replace('/', '_')
        (logs / (key + '.diff')).write_bytes(subprocess.check_output(
            ['git', 'diff', '--binary', '--full-index', 'HEAD'], cwd=root))
        if untracked:
            with tarfile.open(logs / (key + '-untracked.tar'), 'w') as archive:
                for path in untracked:
                    archive.add(root / path, arcname=path)
        ledger.append({'path': name, 'head': output(root, 'git', 'rev-parse', 'HEAD'),
                       'tracked': len(tracked), 'untracked': untracked})
    (logs / 'ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
    return ledger


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True, help='Chromium release tag, e.g. 158.0.8127.37')
    parser.add_argument('--cef-source', required=True, help='Git repository holding the ported CEF commit')
    parser.add_argument('--cef-ref', required=True, help='Branch holding the ported commit')
    parser.add_argument('--cef-commit', required=True, help='Full 40-character commit expected at that branch')
    parser.add_argument('--logs', type=Path, required=True, help='Fresh directory for backups and logs')
    parser.add_argument('--skip-sync', action='store_true', help='Resume after a completed DEPS synchronization')
    args = parser.parse_args()
    if not re.fullmatch(r'1[5-9][0-9]\.0\.[0-9]{4}\.[0-9]+', args.version):
        parser.error('Unexpected Chromium version')
    if not re.fullmatch(r'[0-9a-f]{40}', args.cef_commit):
        parser.error('Pass the full CEF commit')
    args.logs.mkdir(parents=True, exist_ok=args.skip_sync)
    env = dict(build.x2.load(x2.MAIN / 'scripts/chromium-source-lab.py', 'migration_source_lab').ENV)
    with x2.source_tree_lock():
        x2.guard()
        if build.chromium_build_active():
            raise SystemExit('Another Chromium build is active')
        with (args.logs / 'migrate.log').open('a') as log:
            def run(root, *command, extra=None):
                print(root, ' '.join(map(str, command)), flush=True)
                subprocess.run(list(map(str, command)), cwd=root, stdout=log, stderr=subprocess.STDOUT,
                               check=True, env=dict(env, **(extra or {})))
            if output(x2.SRC, 'git', 'remote', 'get-url', 'origin') != CHROMIUM_ORIGIN:
                raise SystemExit('Unexpected Chromium source origin')
            tag = 'refs/tags/' + args.version
            if not args.skip_sync:
                ledger = backup(args.logs)
                run(x2.SRC, 'git', 'fetch', '--depth=1', '--no-tags', 'origin', tag + ':' + tag)
                revision = output(x2.SRC, 'git', 'rev-parse', tag + '^{commit}')
                version = output(x2.SRC, 'git', 'show', revision + ':chrome/VERSION')
                if '.'.join(line.split('=', 1)[1] for line in version.splitlines()) != args.version:
                    raise SystemExit('Release tag/version mismatch')
                # Only patch outputs are cleared; the ledger holds every byte of them.
                for entry in ledger:
                    root = x2.FORK / 'chromium' / entry['path']
                    run(root, 'git', 'checkout', '--', '.')
                    for path in entry['untracked']:
                        (root / path).unlink()
                compatibility = ast.literal_eval(
                    output(args.cef_source, 'git', 'show', args.cef_commit + ':CHROMIUM_BUILD_COMPATIBILITY.txt'))
                depot = compatibility['depot_tools_checkout']
                depot_root = x2.FORK / 'depot_tools'
                if output(depot_root, 'git', 'remote', 'get-url', 'origin') != DEPOT_ORIGIN:
                    raise SystemExit('Unexpected depot_tools origin')
                run(depot_root, 'git', 'fetch', '--depth=1', 'origin', depot)
                run(depot_root, 'git', 'checkout', '--detach', depot)
                run(x2.FORK / 'chromium', x2.FORK / 'depot_tools/gclient', 'sync', '--no-history', '--nohooks',
                    '--revision', 'src@' + revision, '--jobs=8', extra={'DEPOT_TOOLS_UPDATE': '0'})
                (args.logs / 'sync-complete.json').write_text(json.dumps({'version': args.version,
                                                                          'revision': revision}) + '\n')
            cef = x2.CEF_REPO
            if output(cef, 'git', 'status', '--porcelain', '--untracked-files=no'):
                (args.logs / 'cef-before.diff').write_bytes(
                    subprocess.check_output(['git', 'diff', '--binary', 'HEAD'], cwd=cef))
                run(cef, 'git', 'checkout', '--', '.')
            ref = 'refs/heads/' + args.cef_ref
            run(cef, 'git', 'fetch', str(Path(args.cef_source).resolve()), '+' + ref + ':' + ref)
            if output(cef, 'git', 'rev-parse', ref) != args.cef_commit:
                raise SystemExit('Ported CEF branch does not hold the expected commit')
            run(cef, 'git', 'checkout', '--detach', args.cef_commit)
            run(cef, sys.executable, 'tools/patcher.py', '--patch-file', 'runhooks')
            run(x2.FORK / 'chromium', x2.FORK / 'depot_tools/gclient', 'runhooks', extra={'DEPOT_TOOLS_UPDATE': '0'})
            result = subprocess.run(['/bin/sh', 'cef_create_projects.sh'], cwd=cef, stdout=log,
                                    stderr=subprocess.STDOUT,
                                    env=dict(env, GN_DEFINES=CODEC_DEFINES, CEF_ENABLE_ARM64='1',
                                             GN_OUT_CONFIGS=build.CODEC_OUT.split('/', 1)[1],
                                             ORBIT_CEF_PATCHES='1'))
            (args.logs / 'create-projects.json').write_text(json.dumps({'returncode': result.returncode}) + '\n')
            if result.returncode:
                raise SystemExit('CEF project generation or patching failed; see migrate.log')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
