#!/usr/bin/env python3
"""Prepare and build the owned, pinned Chromium/CEF source laboratory."""
import argparse
import ast
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[1]
ROOT = REPO / '.tools/chromium-fork'
EVIDENCE = REPO / 'artifacts/native-chromium-source'
MARKER = 'orbit-chromium-source-v1'
CEF = '4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f'
CHROMIUM = 'd0c02bfad08ec92a6ffcf989e53cd995e6381a4c'
DEPOT = 'b52fe87d04af61df3dd07748ff2c2c0b649dca09'
STATE = {}
BUILD_DIR = 'out/Release_GN_arm64'
GN_DEFINES = ('is_official_build=true is_component_build=false '
              'use_remoteexec=false use_siso=false target_cpu="arm64" '
              'symbol_level=0 chrome_pgo_phase=0')
ENV = os.environ.copy()
ENV.update(DEPOT_TOOLS_UPDATE='0', GIT_TERMINAL_PROMPT='0',
           GIT_LFS_SKIP_SMUDGE='1',
           PATH=str(ROOT / 'local-tools/bin') + os.pathsep + str(ROOT / 'depot_tools') + os.pathsep + ENV['PATH'],
           VPYTHON_VIRTUALENV_ROOT=str(ROOT / 'cache/vpython'),
           CIPD_CACHE_DIR=str(ROOT / 'cache/cipd'),
           XDG_CACHE_HOME=str(ROOT / 'cache'),
           GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.autocrlf', GIT_CONFIG_VALUE_0='false')


def save(**values):
    STATE.update(values, updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                 free_gib=round(shutil.disk_usage(ROOT).free / 2**30, 2))
    temporary = EVIDENCE / 'status.json.tmp'
    temporary.write_text(json.dumps(STATE, indent=2) + '\n')
    temporary.replace(EVIDENCE / 'status.json')


def guard():
    if shutil.disk_usage(ROOT).free < 80 * 2**30:
        raise RuntimeError('Free space below 80 GiB; acquisition stopped without cleanup')


def run(command, cwd=ROOT):
    guard()
    record = {'time': time.time(), 'cwd': str(cwd), 'argv': command}
    with (EVIDENCE / 'commands.jsonl').open('a') as stream:
        stream.write(json.dumps(record) + '\n')
    print(json.dumps(record), flush=True)
    save(command=command, command_cwd=str(cwd))
    process = subprocess.Popen(command, cwd=cwd, env=ENV, start_new_session=True)
    try:
        deadline = time.monotonic() + 24 * 3600
        while process.poll() is None:
            guard()
            if time.monotonic() > deadline:
                raise RuntimeError('Command exceeded 24-hour bound; resume explicitly')
            save(child_pid=process.pid)
            time.sleep(10)
        if process.returncode:
            raise RuntimeError(f'Command failed with exit code {process.returncode}')
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


def output(command, cwd):
    return subprocess.check_output(command, cwd=cwd, env=ENV, text=True).strip()


def checkout(name, url, revision):
    target = ROOT / name
    target.mkdir(parents=True, exist_ok=True)
    if not (target / '.git').exists():
        if any(target.iterdir()):
            raise RuntimeError(f'Nonempty non-git directory requires inspection: {target}')
        run(['git', 'init', str(target)])
        run(['git', 'remote', 'add', 'origin', url], target)
    if 'origin' not in output(['git', 'remote'], target).splitlines():
        run(['git', 'remote', 'add', 'origin', url], target)
    if output(['git', 'remote', 'get-url', 'origin'], target) != url:
        raise RuntimeError(f'Unexpected origin: {target}')
    head = subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=target,
                          capture_output=True, text=True)
    if head.returncode:
        run(['git', 'fetch', '--depth=1', '--no-tags', 'origin', revision], target)
        run(['git', 'checkout', '--detach', revision], target)
    elif head.stdout.strip() != revision:
        raise RuntimeError(f'Unexpected HEAD; refusing reset: {target}')
    if STATE.get('dependencies') != 'sync_completed' and output(['git', 'status', '--porcelain', '--untracked-files=no'], target):
        raise RuntimeError(f'Tracked modifications require review: {target}')
    STATE.setdefault('verified_checkouts', {})[name] = revision
    save()


def prepare():
    if ROOT.is_symlink() or EVIDENCE.is_symlink():
        raise RuntimeError('Symlink root is forbidden')
    if ROOT.exists() and any(ROOT.iterdir()):
        if not (ROOT / '.owner').is_file() or (ROOT / '.owner').read_text() != MARKER:
            raise RuntimeError('Existing target lacks ownership marker; inspect manually')
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / '.owner').write_text(MARKER)
    EVIDENCE.mkdir(parents=True, exist_ok=True)


def verify_dependencies():
    """Check actual dependency HEADs; gitlink metadata can hide failed clones."""
    base = ROOT / 'chromium'
    parsed = ast.parse((base / '.gclient_entries').read_text())
    assignment = next(node for node in parsed.body
                      if isinstance(node, ast.Assign) and
                      any(isinstance(t, ast.Name) and t.id == 'entries'
                          for t in node.targets))
    entries = ast.literal_eval(assignment.value)
    rows = []
    for name, url in entries.items():
        match = re.search(r'@([0-9a-f]{40})$', url) if isinstance(url, str) else None
        if not match:
            continue
        target = base / name
        if not target.resolve().is_relative_to(ROOT.resolve()):
            raise RuntimeError(f'Dependency outside owned root: {name}')
        result = subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=target,
                                env=ENV, capture_output=True, text=True)
        rows.append({'path': name, 'expected': match[1],
                     'actual': result.stdout.strip() if result.returncode == 0 else None})
    mismatches = [row for row in rows if row['actual'] != row['expected']]
    report = {'checked': len(rows), 'mismatches': mismatches, 'entries': rows}
    (EVIDENCE / 'dependency-heads.json').write_text(json.dumps(report, indent=2) + '\n')
    if mismatches:
        raise RuntimeError(f'Incomplete dependency checkouts require inspection: {mismatches}')
    save(dependency_heads_verified=len(rows))


def worker():
    prepare()
    lock = (ROOT / '.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    def interrupted(signum, frame):
        raise RuntimeError(f'Worker interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    previous = EVIDENCE / 'status.json'
    if previous.exists():
        STATE.update(json.loads(previous.read_text()))
    STATE.pop('error', None)
    STATE.update(pid=os.getpid(), state='in_progress')
    STATE.setdefault('verified_checkouts', {})
    STATE.setdefault('compilation', 'not_started')
    try:
        tag = json.loads((EVIDENCE / 'chromium-tag.json').read_text()[4:])
        if tag['commit'] != CHROMIUM:
            raise RuntimeError('Independent Chromium tag resolution mismatch')
        script = EVIDENCE / 'automate-git.py'
        save(reference_script_sha256=hashlib.sha256(script.read_bytes()).hexdigest())
        checkout('depot_tools', 'https://chromium.googlesource.com/chromium/tools/depot_tools.git', DEPOT)
        checkout('chromium/src', 'https://chromium.googlesource.com/chromium/src.git', CHROMIUM)
        checkout('chromium/src/cef', 'https://github.com/chromiumembedded/cef.git', CEF)
        compatibility = ast.literal_eval((ROOT / 'chromium/src/cef/CHROMIUM_BUILD_COMPATIBILITY.txt').read_text())
        tag_ref = compatibility['chromium_checkout']
        resolved = output(['git', 'ls-remote', 'origin', tag_ref], ROOT / 'chromium/src').split()[0]
        if resolved != CHROMIUM:
            raise RuntimeError('CEF compatibility mismatch')
        config = "solutions = [{'name': 'src', 'url': 'https://chromium.googlesource.com/chromium/src.git', 'managed': False, 'deps_file': 'DEPS', 'custom_deps': {}, 'custom_vars': {'checkout_pgo_profiles': False}}]\n"
        config_path = ROOT / 'chromium/.gclient'
        if config_path.exists() and config_path.read_text() != config:
            raise RuntimeError('Unexpected gclient configuration; refusing replacement')
        config_path.write_text(config)
        if STATE.get('dependencies') != 'sync_completed':
            run([str(ROOT / 'depot_tools/gclient'), 'sync', '--no-history', '--nohooks',
                 '--revision', 'src@' + CHROMIUM, '--jobs=8'], ROOT / 'chromium')
            save(dependencies='sync_completed')
        verify_dependencies()
        if not (ROOT / 'depot_tools/python3_bin_reldir.txt').is_file():
            run([str(ROOT / 'depot_tools/ensure_bootstrap')])
        cef_dir = ROOT / 'chromium/src/cef'
        if STATE.get('hooks') != 'completed':
            run([sys.executable, 'tools/patcher.py', '--patch-file', 'runhooks'], cef_dir)
            save(hooks='in_progress')
            run([str(ROOT / 'depot_tools/gclient'), 'runhooks'], ROOT / 'chromium')
            save(hooks='completed')
        ENV.update(GN_DEFINES=GN_DEFINES, GN_OUT_CONFIGS='Release_GN_arm64',
                   CEF_ENABLE_ARM64='1')
        save(projects='in_progress', gn_defines=GN_DEFINES)
        run(['/bin/sh', 'cef_create_projects.sh'], cef_dir)
        # Require the generated build graph in addition to a successful exit.
        if not (ROOT / 'chromium/src' / BUILD_DIR / 'build.ninja').is_file():
            raise RuntimeError('CEF project generation did not produce build.ninja')
        save(state='source_preparation_complete', projects='completed', child_pid=None)
    except BaseException as error:
        save(state='stopped', error=str(error), child_pid=None)
        raise


def build_isolation_prefix():
    """Keep ancestor npm installations out of Chromium's dependency resolution."""
    blocked = [parent / 'node_modules' for parent in ROOT.parents
               if (parent / 'node_modules').is_dir()]
    profile = ROOT / 'build-isolation.sb'
    if profile.is_symlink():
        raise RuntimeError('Symlink build isolation profile is forbidden')
    rules = '(version 1)\n(allow default)\n'
    rules += ''.join('(deny file-read* (subpath ' + json.dumps(str(path)) + '))\n'
                     for path in blocked)
    profile.write_text(rules)
    save(ambient_node_modules_hidden=[str(path) for path in blocked])
    return ['/usr/bin/sandbox-exec', '-f', str(profile)]


def build_worker():
    prepare()
    lock = (ROOT / '.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    STATE.update(json.loads((EVIDENCE / 'status.json').read_text()))
    if STATE.get('projects') != 'completed':
        raise RuntimeError('Complete source preparation before building')
    STATE.pop('error', None)
    save(pid=os.getpid(), state='building', compilation='in_progress',
         build_log_offset=(EVIDENCE / 'build-baseline.log').stat().st_size,
         build_started_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    def interrupted(signum, frame):
        raise RuntimeError(f'Build worker interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    ENV['NINJA_STATUS'] = '[%f/%t %es] '
    try:
        run(build_isolation_prefix() +
            ['nice', '-n', '10', str(ROOT / 'depot_tools/autoninja'),
             '-C', BUILD_DIR, '-j', '12', 'cef', 'cefsimple', 'cefclient'],
            ROOT / 'chromium/src')
        save(state='build_complete', compilation='completed', child_pid=None)
    except BaseException as error:
        save(state='stopped', compilation='stopped', error=str(error), child_pid=None)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'resume', 'status', 'build', 'build-status', '_worker', '_build_worker'])
    action = parser.parse_args().action
    if action in ('status', 'build-status'):
        path = EVIDENCE / 'status.json'
        if not path.exists():
            print('No status manifest yet')
            return
        current = json.loads(path.read_text())
        current['current_free_gib'] = round(shutil.disk_usage(ROOT).free / 2**30, 2)
        pid = current.get('pid')
        process = subprocess.run(['ps', '-p', str(pid), '-o', 'command='],
                                 capture_output=True, text=True) if pid else None
        current['worker_alive'] = bool(process and process.returncode == 0 and
                                       str(Path(__file__).resolve()) in process.stdout)
        print(json.dumps(current, indent=2))
        if action == 'build-status':
            log = EVIDENCE / 'build-baseline.log'
            if log.exists():
                with log.open('rb') as stream:
                    stream.seek(max(current.get('build_log_offset', 0),
                                    log.stat().st_size - 64000))
                    tail = stream.read().decode(errors='replace')
                matches = re.findall(r'\[(\d+)/(\d+) ([\d.]+)s\]', tail)
                if matches:
                    done, total, elapsed = map(float, matches[-1])
                    print(json.dumps({'completed_actions': int(done),
                                      'total_actions': int(total),
                                      'elapsed_seconds': elapsed,
                                      'linear_remaining_hours': round(
                                          elapsed * (total - done) / max(done, 1) / 3600, 2),
                                      'estimate_caveat': 'Early action-rate extrapolation; link/LTO costs vary'}))
                print('\n'.join(tail.splitlines()[-10:]))
        return
    if action == '_build_worker':
        build_worker()
        return
    if action == '_worker':
        worker()
        return
    prepare()
    lock = (ROOT / '.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit('Owned acquisition is already active; use status')
    # Release before spawning; the worker acquires the same exclusive lock.
    fcntl.flock(lock, fcntl.LOCK_UN)
    log_path = EVIDENCE / ('build-baseline.log' if action == 'build' else 'acquisition.log')
    worker_action = '_build_worker' if action == 'build' else '_worker'
    with log_path.open('a') as log:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), worker_action],
                                   cwd=REPO, stdout=log, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
    print(json.dumps({'pid': process.pid, 'log': str(log_path)}))


if __name__ == '__main__':
    main()
