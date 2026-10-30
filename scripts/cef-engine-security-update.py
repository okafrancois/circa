#!/usr/bin/env python3
"""Update the owned Chromium security branch, preserving the applied CEF/Orbit union.

Fetches a same-branch release tag and its changed gitlink dependencies. Records exact
before/after revisions and full binary patches before changing any working files.
Stops on conflicts; never resets a working tree or advances a release configuration.
Inspect DEPS for CIPD/toolchain/hook changes separately; this driver synchronizes Git rolls.
Run the versioned engine build and its qualification separately after inspecting the log.
"""
import argparse
import ast
import importlib.util
import json
from pathlib import Path
import re
import pprint
import subprocess

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('security_engine_build', REPO / 'scripts/cef-engine-extensions-build.py')
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)
x2 = build.x2


def output(root, *command):
    return subprocess.check_output(command, cwd=root, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--logs', type=Path, required=True, help='Fresh directory for source backups and update log')
    args = parser.parse_args()
    if not re.fullmatch(r'156\.0\.8078\.[0-9]+', args.version):
        parser.error('Only the maintained 156.0.8078 security branch is supported')
    args.logs.mkdir(parents=True, exist_ok=False)
    with x2.source_tree_lock():
        x2.guard()
        if build.chromium_build_active():
            raise SystemExit('Another Chromium build is active')
        with (args.logs / 'update.log').open('w') as log:
            def run(root, *command):
                print(root.name, ' '.join(command), flush=True)
                subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
            tag = 'refs/tags/' + args.version
            if output(x2.SRC, 'git', 'remote', 'get-url', 'origin') != 'https://chromium.googlesource.com/chromium/src.git':
                raise SystemExit('Unexpected Chromium source origin')
            run(x2.SRC, 'git', 'fetch', '--depth=1', '--no-tags', 'origin', tag + ':' + tag)
            revision = output(x2.SRC, 'git', 'rev-parse', tag + '^{commit}')
            version_file = output(x2.SRC, 'git', 'show', revision + ':chrome/VERSION')
            actual = '.'.join(line.split('=', 1)[1] for line in version_file.splitlines())
            if actual != args.version:
                raise SystemExit('Release tag/version mismatch')
            old = output(x2.SRC, 'git', 'rev-parse', 'HEAD')
            deps = []
            for line in output(x2.SRC, 'git', 'diff', '--raw', old, revision).splitlines():
                if line.startswith(':160000 160000'):
                    _, name = line.split('\t')
                    deps.append((name, output(x2.SRC, 'git', 'rev-parse', revision + ':' + name)))
            ledger = []
            for name, target in [('.', revision)] + deps:
                root = x2.SRC / name
                if output(root, 'git', 'diff', '--name-only', '--diff-filter=U'):
                    raise SystemExit('Resolve existing source conflicts before updating')
                patch = args.logs.resolve() / (('src' if name == '.' else name.replace('/', '_')) + '-before.patch')
                patch.write_bytes(subprocess.check_output(['git', 'diff', '--binary', '--full-index',
                    '--ignore-submodules=all', 'HEAD'], cwd=root))
                ledger.append({'path': name, 'before': output(root, 'git', 'rev-parse', 'HEAD'),
                               'after': target, 'patch': str(patch)})
            (args.logs / 'source-update.json').write_text(json.dumps(ledger, indent=2) + '\n')
            for entry in ledger:
                root = x2.SRC / entry['path']; patch = Path(entry['patch'])
                if entry['path'] != '.':
                    run(root, 'git', 'fetch', '--depth=1', '--no-tags', 'origin', entry['after'])
                # Only the index is cleared; every working change is already backed up.
                run(root, 'git', 'reset', '--mixed', 'HEAD')
                if patch.stat().st_size:
                    run(root, 'git', 'apply', '-R', str(patch))
                run(root, 'git', 'checkout', '--detach', entry['after'])
                if patch.stat().st_size:
                    run(root, 'git', 'apply', '--3way', str(patch))
                run(root, 'git', 'reset', '--mixed', 'HEAD')
            entries_path = x2.FORK / 'chromium/.gclient_entries'
            if entries_path.exists():
                entries_source = entries_path.read_text()
                (args.logs / 'gclient-entries-before.txt').write_text(entries_source)
                assignment = ast.parse(entries_source).body[0]
                entries = ast.literal_eval(assignment.value)
                for entry in ledger:
                    key = 'src' if entry['path'] == '.' else 'src/' + entry['path']
                    if isinstance(entries.get(key), str):
                        entries[key] = re.sub(r'@[0-9a-f]{40}$', '@' + entry['after'], entries[key])
                entries_path.write_text('entries = ' + pprint.pformat(entries, sort_dicts=False) + '\n')
            run(x2.SRC, 'python3', 'build/util/lastchange.py', '-o', 'build/util/LASTCHANGE')
            print('Updated', len(ledger), 'repositories to', args.version, flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
