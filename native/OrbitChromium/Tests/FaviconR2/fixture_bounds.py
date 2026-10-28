#!/usr/bin/env python3
"""No-socket privacy/accounting regression. Generated request targets stay in memory."""
import importlib.util
import pathlib
import uuid
from types import SimpleNamespace

root = pathlib.Path(__file__).resolve().parents[4]
spec = importlib.util.spec_from_file_location('fixture', root / 'tools/favicon-fixture/server.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
fixture.COUNTERS.clear()
for _ in range(1_000):
    request = SimpleNamespace(path='/' + uuid.uuid4().hex + '?' + uuid.uuid4().hex,
        headers={'Cookie': 'synthetic'}, reply=lambda *a, **k: None)
    fixture.Handler.do_GET(request)
assert dict(fixture.COUNTERS) == {'unknown': 1_000}
for path in fixture.ENDPOINTS - {'/delayed-icon.png'}:
    request = SimpleNamespace(path=path + '?ignored=' + uuid.uuid4().hex,
        headers={'Cookie': 'synthetic'}, reply=lambda *a, **k: None)
    fixture.Handler.do_GET(request)
assert len(fixture.COUNTERS) <= 2 * len(fixture.ENDPOINTS) + 1
assert all(key == 'unknown' or key.removesuffix(':cookie-present') in fixture.ENDPOINTS for key in fixture.COUNTERS)
print('PASS fixed endpoint labels and one unknown bucket; generated targets never emitted')
