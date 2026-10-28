#!/usr/bin/env python3
"""Static GN closure of the staged extensions union (no `gn gen`, no shared output).

For every file the union adds, find the GN target that lists it in the union's own BUILD files
(or report that none does), and for every Orbit include added by the union check that its owner
target is listed. This is source inspection: GN regeneration, `gn check` and the dependency
graph remain the PM build's gate.
"""
from pathlib import Path
import argparse, json, re, subprocess, sys

CEF_BASE = '0e5315e2fd06795cafe7e83bf6bf94a3ab405e8f'
CHROMIUM_BASE = 'd0c02bfad08ec92a6ffcf989e53cd995e6381a4c'


def new_files(stage, shared):
    """Files absent from the pinned bases (not from the shared working tree, which may differ)."""
    for role, repo, base in (('cef', shared / 'cef', CEF_BASE), ('chromium', shared, CHROMIUM_BASE)):
        for path in sorted((stage / role).rglob('*')):
            if path.is_file():
                relative = path.relative_to(stage / role)
                known = subprocess.run(['git', '-C', str(repo), 'cat-file', '-e', f'{base}:{relative}'],
                                       capture_output=True).returncode == 0
                if not known:
                    yield role, relative

def listing(stage, role, relative):
    """BUILD.gn files (union copy first, then shared) that list |relative|."""
    hits = []
    candidates = [stage / role / 'BUILD.gn'] if role == 'cef' else []
    parts = relative.parts
    for depth in range(len(parts) - 1, 0, -1):
        candidates.append(stage / role / Path(*parts[:depth]) / 'BUILD.gn')
    for build in candidates:
        if not build.is_file():
            continue
        base = build.parent.relative_to(stage / role)
        text = build.read_text()
        local = str(relative.relative_to(base)) if str(base) != '.' else str(relative)
        if f'"{local}"' in text:
            target = None
            index = text.index(f'"{local}"')
            for match in re.finditer(r'^\s*(\w+)\("([^"]+)"\)\s*\{', text[:index], re.M):
                target = f'{match.group(1)}("{match.group(2)}")'
            hits.append({'build': str(build.relative_to(stage / role)), 'target': target})
    return hits

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', required=True, type=Path)
    parser.add_argument('--chromium-source', required=True, type=Path)
    args = parser.parse_args()
    rows, unlisted = [], []
    for role, relative in new_files(args.stage, args.chromium_source):
        hits = listing(args.stage, role, relative)
        row = {'role': role, 'file': str(relative), 'listed_in': hits}
        if relative.suffix == '.inc':
            row['note'] = 'textually included by its listed owner'
        elif relative.parts[:2] == ('patch', 'patches'):
            row['note'] = 'CEF patcher input (patch.cfg), not a GN source'
        elif relative.name.endswith('_unittest.mm') or relative.name.endswith('_unittest.cc'):
            row['note'] = 'test source'
        if not hits and 'note' not in row:
            unlisted.append(str(relative))
        rows.append(row)
    print(json.dumps({'new_files': rows, 'unlisted': unlisted}, indent=2))
    sys.exit(0)

if __name__ == '__main__':
    main()
