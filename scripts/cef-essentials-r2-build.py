#!/usr/bin/env python3
"""One controlled, locked essentials R2 application/build; never promotes a candidate."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('x2', REPO / 'scripts/orbit-chromium-x2.py')
x2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(x2)
EVIDENCE = x2.MAIN / 'artifacts/native-orbit-chromium-x2/essentials-r2-controlled'


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, stderr=subprocess.STDOUT)


def idle():
    rows = []
    table = run('/bin/ps', '-axo', 'pid=,ppid=,comm=').decode()
    old = {2651, 2836, 10503, 58275}
    for line in table.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        pid, parent = map(int, fields[:2])
        executable = fields[2]
        # Inspect executable identity without logging unrelated command lines.
        if pid in old or parent in old or any(name in executable for name in
                ('ninja', 'clang', 'make_distrib', 'codecs-worker', 'chromium-worker')):
            rows.append({'pid': pid, 'parent': parent, 'executable': executable})
    if rows:
        raise SystemExit('Active/reused worker or compiler identity; refusing ownership: ' + json.dumps(rows))
    return {'old_worker_ids_absent': sorted(old), 'compiler_and_ninja_scan': rows,
            'process_table_sha256': x2.hashlib.sha256(table.encode()).hexdigest()}


def snapshot(label):
    record = {}
    for name, root in (('cef', x2.CEF_REPO), ('chromium', x2.SRC)):
        record[name + '_head'] = run('git', 'rev-parse', 'HEAD', cwd=root).decode().strip()
        for kind, options in (('status', ['status', '--porcelain']),
                              ('working', ['diff', '--binary']),
                              ('index', ['diff', '--cached', '--binary'])):
            data = run('git', *options, cwd=root)
            (EVIDENCE / (label + '-' + name + '-' + kind + '.txt')).write_bytes(data)
            record[name + '_' + kind + '_sha256'] = x2.hashlib.sha256(data).hexdigest()
    paths = {'gn_args': x2.SRC / x2.OUT / 'args.gn',
             'compiler_revision': x2.SRC / 'third_party/llvm-build/Release+Asserts/cr_build_revision',
             'compiler': x2.SRC / 'third_party/llvm-build/Release+Asserts/bin/clang',
             'build_profile': x2.FORK / 'build-isolation.sb',
             'framework': x2.SRC / x2.OUT / 'Chromium Embedded Framework.framework/Chromium Embedded Framework'}
    record['files'] = {name: {'path': str(path), 'sha256': x2.sha256(path)} for name, path in paths.items()}
    (EVIDENCE / (label + '.json')).write_text(json.dumps(record, indent=2) + '\n')
    return record


def main():
    if EVIDENCE.exists() or (x2.DISTRIB / 'orbit-essentials-r2').exists():
        raise SystemExit('Candidate or evidence already exists; preserve it and stop')
    with x2.source_tree_lock():
        worker_scan = idle()
        EVIDENCE.mkdir(parents=True)
        (EVIDENCE / 'ownership.json').write_text(json.dumps({
            'pid': os.getpid(), 'acquired_utc': datetime.now(timezone.utc).isoformat(),
            'worker_scan': worker_scan, 'product_source': run('git', 'rev-parse', 'HEAD', cwd=REPO).decode().strip(),
            'lock': str(x2.FORK / '.lock')}, indent=2) + '\n')
        before = snapshot('before')
        checker = EVIDENCE / 'exact-check.json'
        subprocess.run([sys.executable, str(REPO / 'scripts/check_cef_essentials_patch.py'),
                        '--chromium-source', str(x2.SRC), '--report', str(checker)], check=True)
        if run('git', 'status', '--porcelain', cwd=x2.CEF_REPO).strip():
            raise SystemExit('CEF is dirty; stop without application')
        if run('git', 'diff', '--cached', '--name-only', cwd=x2.SRC).strip():
            raise SystemExit('Chromium index is dirty; stop without application')
        patch = REPO / 'native/OrbitChromium/cef-patches/pending/ch-essentials-0001-essential-surfaces.patch'
        run('git', 'switch', '-c', 'orbit/essentials-r2-controlled', cwd=x2.CEF_REPO)
        run('git', 'apply', '--check', str(patch), cwd=x2.CEF_REPO)
        run('git', 'apply', '--index', str(patch), cwd=x2.CEF_REPO)
        for name in ('orbit_essentials_sad_tab', 'orbit_essentials_folder_upload'):
            nested = x2.CEF_REPO / 'patch/patches' / (name + '.patch')
            run('git', 'apply', '-p0', '--check', str(nested), cwd=x2.SRC)
            run('git', 'apply', '-p0', str(nested), cwd=x2.SRC)
        expected = json.loads(checker.read_text())
        for root, key in ((x2.CEF_REPO, 'cef_patched_sha256'), (x2.SRC, 'chromium_patched_sha256')):
            for name, digest in expected[key].items():
                assert x2.sha256(root / name) == digest, name
        # Only the two reviewed Chromium targets may differ from the original diff.
        targets = list(expected['chromium_patched_sha256'])
        unaffected = run('git', 'diff', '--binary', '--', '.', *[':(exclude)' + name for name in targets], cwd=x2.SRC)
        (EVIDENCE / 'unaffected-after.diff').write_bytes(unaffected)
        # Reverse on a private snapshot is already proved by the exact checker;
        # no reset of any shared source is needed.
        run('git', 'commit', '-m', 'Orbit essentials R2: reviewed logical fullscreen, confirmed folders and sad-tab guard', cwd=x2.CEF_REPO)
        after = snapshot('applied')
        source_lab = x2.load(x2.MAIN / 'scripts/chromium-source-lab.py', 'source_lab')
        env = dict(source_lab.ENV, ORBIT_CEF_PATCHES='1', NINJA_STATUS='[%f/%t %es] ')
        command = ['/usr/bin/sandbox-exec', '-f', str(x2.FORK / 'build-isolation.sb'),
                   'nice', '-n', '10', str(x2.FORK / 'depot_tools/autoninja'),
                   '-C', x2.OUT, '-j', '12', 'cef', 'cefsimple']
        (EVIDENCE / 'build-command.json').write_text(json.dumps({'command': command,
            'cwd': str(x2.SRC), 'environment_overrides': {'ORBIT_CEF_PATCHES': '1'},
            'source_head': after['cef_head']}, indent=2) + '\n')
        with (EVIDENCE / 'build.log').open('wb') as stream:
            code = subprocess.run(command, cwd=x2.SRC, env=env, stdout=stream, stderr=subprocess.STDOUT).returncode
        (EVIDENCE / 'build-exit.json').write_text(json.dumps({'exit': code}) + '\n')
        built = snapshot('built')
        assert before['files']['gn_args']['sha256'] == built['files']['gn_args']['sha256']
        if code:
            return code
        from types import SimpleNamespace
        with (EVIDENCE / 'distrib.log').open('w') as stream:
            # distrib itself is called under the still-held source lock.
            import contextlib
            with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
                x2.distrib(SimpleNamespace(flavor='orbit-essentials-r2', replace=False))
        (EVIDENCE / 'complete.json').write_text(json.dumps({'cef_head': built['cef_head'],
            'framework_sha256': built['files']['framework']['sha256'],
            'finished_utc': datetime.now(timezone.utc).isoformat(), 'promoted': False}, indent=2) + '\n')
    (EVIDENCE / 'released.json').write_text(json.dumps({'pid': os.getpid(),
        'released_utc': datetime.now(timezone.utc).isoformat(), 'worker_scan': idle()}) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
