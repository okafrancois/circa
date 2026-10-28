#!/usr/bin/env python3
"""Check pending essentials patches in a private stage, without building CEF."""
import argparse
import ast
import hashlib
import json
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

CEF_HEAD = '0e3b767d39fa37f61101c2e31e945489789ed75d'
CHROMIUM_HEAD = 'd0c02bfad08ec92a6ffcf989e53cd995e6381a4c'
TARGETS = ('chrome/browser/file_select_helper.cc',
           'chrome/browser/ui/sad_tab_controller.cc')
CEF_TARGETS = ('libcef/browser/orbit/orbit_browser_window.h',
               'libcef/browser/orbit/orbit_browser_window.mm',
               'libcef/browser/orbit/orbit_cef_api.mm',
               'libcef/browser/file_dialog_manager.cc', 'patch/patch.cfg')


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, stderr=subprocess.STDOUT)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def patch_entries(text):
    tree = ast.parse(text)
    assignment = next(node for node in tree.body if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == 'patches'
                              for target in node.targets))
    return ast.literal_eval(assignment.value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chromium-source', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    source = args.chromium_source.resolve()
    cef = source / 'cef'
    repo = Path(__file__).resolve().parents[1]
    pending = repo / 'native/OrbitChromium/cef-patches/pending'
    patch = pending / 'ch-essentials-0001-essential-surfaces.patch'
    pins_path = pending / 'cef-essentials-r2-base.json'
    pins = json.loads(pins_path.read_text())
    assert pins['cef_head'] == CEF_HEAD and pins['chromium_head'] == CHROMIUM_HEAD
    if run('git', 'rev-parse', 'HEAD', cwd=cef).decode().strip() != CEF_HEAD:
        raise SystemExit('CEF base changed: rebase and review before validation')
    if run('git', 'rev-parse', 'HEAD', cwd=source).decode().strip() != CHROMIUM_HEAD:
        raise SystemExit('Chromium base changed: rebase and review before validation')
    # Bind applicability to working bytes as well as Git IDs: Chromium already
    # contains upstream CEF patches which are not represented by Chromium HEAD.
    watched = [cef / name for name in pins['cef_input_sha256']]
    watched += [source / name for name in TARGETS]
    before = {path: path.read_bytes() for path in watched}
    for root, key in ((cef, 'cef_input_sha256'),
                      (source, 'chromium_input_sha256')):
        for name, expected in pins[key].items():
            if digest(before[root / name]) != expected:
                raise SystemExit('Working source differs from reviewed pinned bytes: ' + name)
    config = (cef / 'patch/patch.cfg').read_text()
    repaired = config.replace("'condition': 'ORBIT_CEF_PATCHES',\n  }\n  # Native",
                              "'condition': 'ORBIT_CEF_PATCHES',\n  },\n  # Native")
    baseline_entries = patch_entries(repaired)
    with tempfile.TemporaryDirectory(prefix='orbit-cef-essentials-check-') as temp:
        stage = Path(temp)
        private_cef = stage / 'cef'
        run('git', 'clone', '--shared', '--no-checkout', str(cef), str(private_cef))
        run('git', 'checkout', '--detach', CEF_HEAD, cwd=private_cef)
        # Require exact baseline CEF bytes, so an uncommitted shared change
        # cannot be accidentally treated as reviewed source.
        for name in pins['cef_input_sha256']:
            if (private_cef / name).read_bytes() != before[cef / name]:
                raise SystemExit('CEF working file differs from pinned base: ' + name)
        run('git', 'apply', '--check', str(patch), cwd=private_cef)
        run('git', 'apply', '--index', str(patch), cwd=private_cef)
        run('git', 'apply', '--reverse', '--check', str(patch), cwd=private_cef)
        changed = set(run('git', 'diff', '--cached', '--name-only', cwd=private_cef)
                      .decode().splitlines())
        added = {'patch/patches/orbit_essentials_sad_tab.patch',
                 'patch/patches/orbit_essentials_folder_upload.patch'}
        assert changed == set(CEF_TARGETS) | added, 'Unexpected outer patch scope'
        for name in pins['cef_input_sha256']:
            if name not in CEF_TARGETS:
                assert (private_cef / name).read_bytes() == before[cef / name], name
        entries = patch_entries((private_cef / 'patch/patch.cfg').read_text())
        assert entries[:-2] == baseline_entries, 'Existing patch entries changed'
        assert [entry['name'] for entry in entries[-2:]] == [
            'orbit_essentials_sad_tab', 'orbit_essentials_folder_upload']
        assert all(entry.get('condition') == 'ORBIT_CEF_PATCHES'
                   for entry in entries[-2:])
        private_chromium = stage / 'chromium'
        private_chromium.mkdir()
        run('git', 'init', '-q', str(private_chromium))
        for name in TARGETS:
            target = private_chromium / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(before[source / name])
        nested = {}
        for name in ('orbit_essentials_sad_tab', 'orbit_essentials_folder_upload'):
            path = private_cef / 'patch/patches' / (name + '.patch')
            # Same strip level as CEF tools/git_util.py, not git's default -p1.
            run('git', 'apply', '-p0', '--check', str(path), cwd=private_chromium)
            run('git', 'apply', '-p0', str(path), cwd=private_chromium)
            run('git', 'apply', '-p0', '--reverse', '--check', str(path),
                cwd=private_chromium)
            nested[name] = digest(path.read_bytes())
        output_hashes = {name: digest((private_chromium / name).read_bytes())
                         for name in TARGETS}
        cef_output_hashes = {name: digest((private_cef / name).read_bytes())
                             for name in CEF_TARGETS}
    assert all(path.read_bytes() == data for path, data in before.items()), \
        'Shared watched source changed during private validation; re-run after ownership'
    report = {
        'schema': 2, 'time_utc': datetime.now(timezone.utc).isoformat(),
        'status': 'private-applicability-passed-runtime-unverified',
        'cef_head': CEF_HEAD, 'chromium_head': CHROMIUM_HEAD,
        'base_pins_sha256': digest(pins_path.read_bytes()),
        'preserved_cef_files': len(pins['cef_input_sha256']) - len(CEF_TARGETS),
        'patch_sha256': digest(patch.read_bytes()), 'nested_patch_sha256': nested,
        'cef_input_sha256': {name: digest(before[cef / name]) for name in pins['cef_input_sha256']},
        'chromium_input_sha256': {name: digest(before[source / name]) for name in TARGETS},
        'cef_patched_sha256': cef_output_hashes,
        'chromium_patched_sha256': output_hashes,
        'checks': ['exact pinned CEF and actual Chromium input SHA-256',
                   'outer git apply --check, --index and reverse --check',
                   'v3 transfer and existing nested patch files unchanged',
                   'patch.cfg parses and preserves all existing entries',
                   'nested patches apply and reverse-check with CEF strip level -p0',
                   'watched shared source bytes unchanged'],
        'not_run': ['CEF compilation', 'folder upload acceptance/cancellation',
                    'document.exitFullscreen runtime state',
                    'renderer termination, application survival, reload'],
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(report['status'])


if __name__ == '__main__':
    main()
