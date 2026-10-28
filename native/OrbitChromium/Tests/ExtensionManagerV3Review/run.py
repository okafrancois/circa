#!/usr/bin/env python3
"""Independent source-only extension-manager falsification; no app/CEF execution."""
from pathlib import Path
import subprocess
import os

here = Path(__file__).resolve().parent
root = here.parents[3]
author = here.with_name('ExtensionManagerV3')
out = root / 'native/OrbitChromium/build/extension-manager-v3'
# Preserve and run every incoming assertion, including the specific old-body red.
for args in (['--baseline'], []):
    subprocess.run(['python3', str(author / 'run.py'), *args], check=True)
fixture = (author / 'fixture.mm').read_text()
marker = ' puts("PASS actual v3/v4 manager bodies'
assert fixture.count(marker) == 1
fixture = fixture.replace(marker, (here / 'native.inc').read_text() + '\n' + marker)
(out / 'review.mm').write_text(fixture)
subprocess.run(['clang++', '-std=c++20', '-fobjc-arc', '-UNDEBUG', '-fsanitize=address,undefined',
                '-I' + str(root / 'native/OrbitChromium/Bridge'), '-I' + str(out),
                str(out / 'review.mm'), '-framework', 'AppKit', '-o', str(out / 'review')], check=True)
subprocess.run([str(out / 'review')], check=True)
adapter = (out / 'adapter.swift').read_text()
marker = '        print("PASS actual Swift service properties/manager adapter'
assert adapter.count(marker) == 1
adapter = adapter.replace(marker, (here / 'adapter.inc').read_text() + '\n' + marker)
(out / 'review.swift').write_text(adapter)
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(out / 'review.swift'),
                '-o', str(out / 'review-adapter')], check=True)
subprocess.run([str(out / 'review-adapter')], check=True)
site = (root / 'native/Sources/Orbit/SiteControls/BrowserSiteControls.swift').read_text()
current = site[site.index('    private func isCurrent('):site.index('\n    func request(', site.index('    private func isCurrent('))]
valid_start = site.index('        let valid: @MainActor () -> Bool =')
valid = site[valid_start:site.index('\n        rows.append(', valid_start)]
manager_start = site.index('        if let manager =', site.index('    func appendExtensionRows('))
manager = site[manager_start:site.index('        guard let host =', manager_start)]
fixture = (here / 'site.swift').read_text().replace('/* CURRENT */', current).replace('/* VALID */', valid).replace('/* MANAGER */', manager)
(out / 'review-site.swift').write_text(fixture)
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(out / 'review-site.swift'),
                '-o', str(out / 'review-site')], check=True)
subprocess.run([str(out / 'review-site')], check=True)
palette = (root / 'native/Sources/Orbit/Palette/BrowserPaletteController.swift').read_text()
start = palette.index('            case .command(let id):', palette.index('    func accept('))
end = palette.index('\n\n            }', start)
body = palette[start:end].split('\n', 1)[1]
baseline = subprocess.check_output(['git', '-C', str(root), 'show',
    'c47cb8398bdacc45fd1cb0dbcb5f06006efc1eda:native/Sources/Orbit/Palette/BrowserPaletteController.swift'], text=True)
assert body in baseline, 'Palette finding must be reclassified if no longer inherited'
fixture = (here / 'palette.swift').read_text().replace('/* COMMAND CASE */', body)
(out / 'review-palette.swift').write_text(fixture)
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(out / 'review-palette.swift'),
                '-o', str(out / 'review-palette')], check=True)
subprocess.run([str(out / 'review-palette')], check=True)

strict = subprocess.run([str(out / 'review-palette')], capture_output=True, text=True,
    env={**os.environ, 'ORBIT_REVIEW_REQUIRE_ORIGINAL_DOCUMENT': '1'})
assert strict.returncode != 0 and 'REVIEW original document must survive queue drain' in strict.stderr, strict
print('EXPECTED RED current and baseline palette command body: original document authority is not retained across queue drain')
