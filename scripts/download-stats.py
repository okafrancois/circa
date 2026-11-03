#!/usr/bin/env python3
"""Read GitHub's release-file counters without downloading any release assets."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def summarize(releases):
    rows = []
    for release in releases:
        tag = release.get('tag_name', '')
        if release.get('draft') or release.get('prerelease') or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
            continue
        counts = {'dmg': 0, 'zip': 0, 'delta': 0}
        for asset in release.get('assets', []):
            name, count = asset.get('name', ''), asset.get('download_count', 0)
            if not isinstance(count, int) or count < 0:
                continue
            if re.fullmatch(r'(?:Circa|Orbit)(?:-[0-9]+\.[0-9]+\.[0-9]+)?\.dmg', name):
                counts['dmg'] += count
            elif re.fullmatch(r'(?:Circa|Orbit)-[0-9]+\.[0-9]+\.[0-9]+\.zip', name):
                counts['zip'] += count
            elif re.fullmatch(r'(?:Circa|Orbit)[0-9]+-[0-9]+\.delta', name):
                counts['delta'] += count
        rows.append({'version': tag, 'publishedAt': release.get('published_at'), **counts})
    rows.sort(key=lambda row: tuple(map(int, row['version'][1:].split('.'))), reverse=True)
    totals = {key: sum(row[key] for row in rows) for key in ['dmg', 'zip', 'delta']}
    return {'totals': totals, 'releaseCount': len(rows), 'releases': rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', default=json.loads((Path(__file__).resolve().parents[1] / 'release/config.json').read_text())['repository'])
    parser.add_argument('--limit', type=int, default=20, help='Table rows; 0 shows every release. Totals always include every release.')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository) or not 0 <= args.limit <= 500:
        parser.error('Invalid repository or limit')
    pages = json.loads(subprocess.check_output(['gh', 'api', '--paginate', '--slurp',
        f'repos/{args.repository}/releases?per_page=100'], text=True))
    data = summarize([release for page in pages for release in page])
    data['repository'] = args.repository
    if args.json:
        print(json.dumps(data, indent=2))
        return
    print('# Release file downloads\n')
    print('GitHub counters include repeat downloads, automatic updates, CI and tests. They are **not unique users or installations**.\n')
    print('| All published browser releases | DMG installers | Full ZIP archives | Delta updates |\n| --- | ---: | ---: | ---: |')
    print(f"| {data['releaseCount']} | {data['totals']['dmg']} | {data['totals']['zip']} | {data['totals']['delta']} |\n")
    print('DMG totals include the versioned installer and the stable download alias. Feed, engine, website and debug assets are excluded.\n')
    print('| Release | DMG installers | Full ZIP archives | Delta updates |\n| --- | ---: | ---: | ---: |')
    for row in data['releases'][:args.limit or None]:
        print(f"| [{row['version']}](https://github.com/{args.repository}/releases/tag/{row['version']}) | {row['dmg']} | {row['zip']} | {row['delta']} |")


if __name__ == '__main__':
    main()
