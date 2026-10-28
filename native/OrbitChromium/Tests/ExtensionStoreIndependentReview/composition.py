#!/usr/bin/env python3
"""Build a private source union; optionally run only stand-alone manager fixtures."""
from pathlib import Path
import hashlib
import io
import json
import shutil
import subprocess
import sys
import tarfile

here = Path(__file__).resolve().parent
root = here.parents[3]
parent = root / '.tools/review-extension-store'
union = parent / 'union'
if union.exists():
    shutil.rmtree(union)
union.mkdir(parents=True)
def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args])
def original(commit, path):
    return git('show', commit + ':' + path).decode()
with tarfile.open(fileobj=io.BytesIO(git('archive', 'c7ca6f11', 'native', 'scripts'))) as archive:
    archive.extractall(union)
site_path = 'native/Sources/Orbit/SiteControls/BrowserSiteControls.swift'
# A direct patch conflicts at the adjacent removed-manager/changed-Store rows.
# Preserve the c7 Store row verbatim while moving the f9 manager row above inventory.
for commit in ['f9e17035', 'd193daa4', '5703f25ac', '7555fe94a']:
    args = ['diff', commit + '^', commit, '--', 'native']
    if commit == 'f9e17035':
        args += [':(exclude)' + site_path]
    subprocess.run(['git', '-C', str(root), 'apply', '--directory=' + str(union.relative_to(root)), '-'],
                   input=git(*args), check=True)
site = (union / site_path).read_text()
start = site.index('            rows.append(SiteControlButton(siteText("extensions.manage"')
end = site.index('            rows.append(SiteControlButton(siteText("extensions.store"', start)
site = site[:start] + site[end:]
manager = original('f9e17035', site_path)
start = manager.index('        if let manager =', manager.index('    func appendExtensionRows('))
end = manager.index('        guard let host =', start)
site = site.replace('        guard let host = owner?.engine.extensions else {',
                    manager[start:end] + '        guard let host = owner?.engine.extensions else {', 1)
site = site.replace('siteText("extensions.unavailable",\n                "Extensions require an updated Chromium build.")',
                    'siteText("extensions.controlsUnavailable",\n                "Native extension controls require an updated Chromium build.")')
(union / site_path).write_text(site)
def store_row(text):
    start = text.index('            rows.append(SiteControlButton(siteText("extensions.store"')
    return text[start:text.index('\n            })', start) + len('\n            })')]
assert store_row(site) == store_row(original('c7ca6f11', site_path))
assert site.count('identifier: "extensions-manage"') == 1
# All native ABI/privilege code is exactly the reviewed manager-only lot.
for path in git('diff', '--name-only', 'f9e17035^', 'f9e17035', '--', 'native/OrbitChromium/Bridge',
                'native/OrbitChromium/ChromiumEngine').decode().splitlines():
    assert (union / path).read_text() == original('f9e17035', path), path
for path in git('diff', '--name-only', '5703f25ac^', '5703f25ac', '--', 'native/Sources').decode().splitlines():
    assert (union / path).read_text() == original('5703f25ac', path), path
palette = 'native/Sources/Orbit/Palette/BrowserPaletteController.swift'
assert (union / palette).read_text() == original('f9e17035', palette)
# The existing manager fixture extracts the whole daily-command type. Add only its missing
# controller signature; fail if invoked, so this stub cannot pretend to validate Store behavior.
fixture_path = 'native/OrbitChromium/Tests/ExtensionManagerV3/commands.swift'
fixture = (union / fixture_path).read_text()
marker = '    func submitAddress(_ text: String) {}'
assert fixture.count(marker) == 1
(union / fixture_path).write_text(fixture.replace(marker, marker +
    '\n    func openTab(url: URL) { preconditionFailure("Store route outside manager fixture") }'))
production = {str(p.relative_to(union)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in union.glob('native/**/*') if p.is_file() and ('/Sources/' in str(p) or
              '/Bridge/' in str(p) or '/ChromiumEngine/' in str(p))}
(parent / 'composition.json').write_text(json.dumps({
    'commits': ['c7ca6f11', 'f9e17035', 'd193daa4', '5703f25ac', '7555fe94a'],
    'conflict': site_path + ': adjacent manager removal and changed Store row',
    'fixtureAPI': fixture_path + ': add openTab(url: URL) fail-if-used stub',
    'nativeManagerAndPrivilegeSourcesExactlyF9': True,
    'footerSourcesExactly5703': True,
    'paletteExactlyF9IncludingInheritedP2': True,
    'productionSourceHashes': production,
}, indent=2) + '\n')
print('PASS private source composition; exact Store row, v3/privilege and footer preservation')
if sys.argv[1:] == ['--test']:
    subprocess.run(['python3', str(union / 'native/OrbitChromium/Tests/ExtensionManagerV3Review/run.py')], check=True)
elif sys.argv[1:]:
    raise SystemExit('Usage: composition.py [--test]')
