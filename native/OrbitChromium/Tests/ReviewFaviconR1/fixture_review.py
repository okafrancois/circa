#!/usr/bin/env python3
"""Exercise request accounting without opening a socket or starting the fixture."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace

root = Path(__file__).resolve().parents[4]
spec = importlib.util.spec_from_file_location('fixture', root / 'tools/favicon-fixture/server.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
fixture.COUNTERS.clear()
for i in range(64):
    request = SimpleNamespace(path=f'/unknown-synthetic-{i}', headers={}, reply=lambda *a, **k: None)
    fixture.Handler.do_GET(request)
unknown = [key for key in fixture.COUNTERS if key.startswith('/unknown-synthetic-')]
print(f'REVIEW arbitrary unknown request paths retained: {len(unknown)}')
assert not unknown, 'Counters must only retain fixed synthetic endpoint names, never arbitrary paths'
