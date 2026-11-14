"""Offline checks of the r20 security roll pins; no source tree or build is touched."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'native/OrbitChromium/cef-patches'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class EngineR20Tests(unittest.TestCase):
    def test_pins_preserve_the_complete_r19_union(self):
        r19 = json.loads((PATCHES / 'engine-r19/source.json').read_text())
        r20 = json.loads((PATCHES / 'engine-r20/source.json').read_text())
        self.assertRegex(r20['chromium_tag'], r'^156\.0\.8078\.[0-9]+$')
        self.assertGreater(int(r20['chromium_tag'].rsplit('.', 1)[1]), int(r19['chromium_tag'].rsplit('.', 1)[1]))
        self.assertRegex(r20['chromium_commit'], r'^[0-9a-f]{40}$')
        self.assertEqual(r20['previous_chromium_commit'], r19['chromium_commit'])
        self.assertEqual(r20['previous_flavor'], r19['flavor'])
        self.assertEqual(r20['flavor'], 'orbit-engine-extensions-r20')
        for key in ('cef_base', 'side_api_version', 'cef_parent_commit', 'cef_patch_sha256',
                    'chromium_patch_sha256', 'incremental_patch'):
            self.assertEqual(r20[key], r19[key], key)
        self.assertEqual(set(r20['dependencies']), set(r19['dependencies']))
        self.assertTrue(all(re.fullmatch(r'[0-9a-f]{40}', value) for value in r20['dependencies'].values()))
        for role in ('cef', 'chromium'):
            patch_file = PATCHES / 'engine-r18' / (role + '.patch')
            self.assertEqual(hashlib.sha256(patch_file.read_bytes()).hexdigest(), r20[role + '_patch_sha256'])
        for name in r20['preserved_chromium_patches']:
            self.assertTrue((PATCHES / name).is_file(), name)
        builder = (ROOT / 'scripts/cef-engine-r20-build.py').read_text()
        self.assertIn("PINS = PATCHES / 'engine-r20/source.json'", builder)
        self.assertIn("FLAVOR = 'orbit-engine-extensions-r20'", builder)

    def test_incremental_free_space_guard_has_a_floor(self):
        x2 = load('x2_guard', ROOT / 'scripts/orbit-chromium-x2.py')
        self.assertIn('orbit-engine-extensions-r20', x2.PATCHED_FLAVORS)
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(x2.free_gib_guard(), x2.FREE_GIB_GUARD)
        with patch.dict(os.environ, {'ORBIT_ENGINE_FREE_GIB_GUARD': '50'}):
            self.assertEqual(x2.free_gib_guard(), 50)
        with patch.dict(os.environ, {'ORBIT_ENGINE_FREE_GIB_GUARD': '500'}):
            self.assertEqual(x2.free_gib_guard(), x2.FREE_GIB_GUARD)
        with patch.dict(os.environ, {'ORBIT_ENGINE_FREE_GIB_GUARD': '20'}):
            with self.assertRaises(SystemExit):
                x2.free_gib_guard()


if __name__ == '__main__':
    unittest.main()
