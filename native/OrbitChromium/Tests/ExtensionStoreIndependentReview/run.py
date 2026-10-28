#!/usr/bin/env python3
"""Independent exact-route red/green; no application, web engine or GUI runtime."""
from pathlib import Path
import subprocess

here = Path(__file__).resolve().parent
root = here.parents[3]
out = root / '.tools/review-extension-store/routes'
out.mkdir(parents=True, exist_ok=True)
for commit, expected in [('cfb16ef66b3fd43f3206afb2d2f4e0ba3533dedf', 42),
                         ('c7ca6f11ca7813149f38a2dfe06719a44d59bbae', 0)]:
    def source(path):
        return subprocess.check_output(['git', '-C', str(root), 'show', commit + ':' + path], text=True)
    daily = source('native/Sources/Orbit/Commands/BrowserDailyCommands.swift')
    marker = '        try! registry.register(.addExtension) { controller, _ in\n'
    start = daily.index(marker) + len(marker)
    body = daily[start:daily.index('\n        }', start)]
    site = source('native/Sources/Orbit/SiteControls/BrowserSiteControls.swift')
    start = site.index('            rows.append(SiteControlButton(siteText("extensions.store"')
    row = site[start:site.index('\n            })', start) + len('\n            })')]
    fixture = (here / 'routes.swift').read_text().replace('/* ADD BODY */', body).replace('/* SITE ROW */', row)
    path = out / (commit[:8] + '.swift')
    path.write_text(fixture)
    exe = path.with_suffix('')
    subprocess.run(['swiftc', '-j', '2', '-num-threads', '2', '-swift-version', '6',
                    '-parse-as-library', str(path), '-o', str(exe)], check=True)
    result = subprocess.run([str(exe)], capture_output=True, text=True)
    assert result.returncode == expected, (commit, result.returncode, result.stdout, result.stderr)
    assert ('RED route replaces source' if expected else 'PASS exact Add Extension') in result.stdout
    print(commit[:8], result.stdout.strip())
