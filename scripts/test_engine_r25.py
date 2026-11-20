"""Offline checks of the r25 pins: the r24 composition, unchanged, on 158.0.8127.65; no source tree or build is touched."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'native/OrbitChromium/cef-patches'


class EngineR25Tests(unittest.TestCase):
    def setUp(self):
        self.pins = json.loads((PATCHES / 'engine-r25/source.json').read_text())
        self.r24 = json.loads((PATCHES / 'engine-r24/source.json').read_text())

    def test_same_branch_security_release(self):
        self.assertEqual(self.pins['flavor'], 'orbit-engine-extensions-r25')
        self.assertEqual(self.pins['previous_flavor'], 'orbit-engine-extensions-r24')
        self.assertEqual(self.pins['union_from'], 'engine-r24')
        self.assertEqual(self.pins['chromium_tag'], '158.0.8127.65')
        self.assertEqual(self.pins['previous_chromium_tag'], self.r24['chromium_tag'])
        self.assertEqual(self.pins['previous_chromium_commit'], self.r24['chromium_commit'])
        self.assertNotEqual(self.pins['chromium_commit'], self.r24['chromium_commit'])
        # Same milestone and branch: a security roll, not a migration.
        self.assertEqual(self.pins['chromium_tag'].rsplit('.', 1)[0], self.r24['chromium_tag'].rsplit('.', 1)[0])
        self.assertGreater(int(self.pins['chromium_tag'].rsplit('.', 1)[1]), int(self.r24['chromium_tag'].rsplit('.', 1)[1]))
        for key in ('cef_branch', 'cef_base', 'cef_tree', 'depot_tools', 'cef_patch_sha256',
                    'chromium_patch_sha256', 'side_api_version', 'webauthn_keychain_access_group'):
            self.assertEqual(self.pins[key], self.r24[key], key)
        # Every r24 dependency is still pinned; the roll may add one it changed.
        self.assertLessEqual(set(self.r24['dependencies']), set(self.pins['dependencies']))

    def test_r24_composition_is_carried_unchanged(self):
        previous = self.pins['previous_deltas']
        self.assertEqual(previous['r22'], self.r24['previous_deltas']['r22'])
        self.assertEqual(previous['r23'], self.r24['previous_deltas']['r23'])
        self.assertEqual(previous['r24'], {
            'chromium': {'patch': 'engine-r24/' + self.r24['chromium_delta_patch'],
                         'sha256': self.r24['chromium_delta_patch_sha256']},
            'cef': {'patch': 'engine-r24/' + self.r24['cef_delta_patch'],
                    'sha256': self.r24['cef_delta_patch_sha256']}})
        deltas = [previous['r22'], previous['r23'], previous['r24']['chromium'], previous['r24']['cef']]
        for delta in deltas:
            self.assertEqual(hashlib.sha256((PATCHES / delta['patch']).read_bytes()).hexdigest(), delta['sha256'])
        for name in ('cef', 'chromium'):
            data = (PATCHES / 'engine-r21' / (name + '.patch')).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), self.pins[name + '_patch_sha256'])
        # No new patch ships with r25.
        self.assertEqual(sorted(p.name for p in (PATCHES / 'engine-r25').iterdir()), ['README.md', 'source.json'])

    def test_release_points_at_r25(self):
        config = json.loads((ROOT / 'release/config.json').read_text())
        engine = json.loads((ROOT / 'release/engine.json').read_text())
        self.assertEqual(config['cef_flavor'], self.pins['flavor'])
        self.assertEqual(engine['flavor'], self.pins['flavor'])
        self.assertEqual(engine['url'], 'https://github.com/okafrancois/circa/releases/download/engine-r25/'
                                        'orbit-engine-extensions-r25.tar.gz')
        for key in ('archive_sha256', 'framework_sha256', 'wrapper_sha256'):
            self.assertRegex(engine[key], r'^[0-9a-f]{64}$')

    def test_builder_and_flavor_registry(self):
        builder = (ROOT / 'scripts/cef-engine-r25-build.py').read_text()
        self.assertIn("FLAVOR = 'orbit-engine-extensions-r25'", builder)
        r24_builder = (ROOT / 'scripts/cef-engine-r24-build.py').read_text()
        cmake = (ROOT / 'native/OrbitChromium/CMakeLists.txt').read_text()
        self.assertEqual(re.search(r"WRAPPER_API_VERSION = '([0-9]+)'", r24_builder)[1],
                         re.search(r'CEF_API_VERSION[^0-9]*([0-9]+)', cmake)[1])
        self.assertIn('WRAPPER_API_VERSION = r24.WRAPPER_API_VERSION', builder)
        spec = importlib.util.spec_from_file_location('x2_r25', ROOT / 'scripts/orbit-chromium-x2.py')
        x2 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(x2)
        self.assertIn('orbit-engine-extensions-r25', x2.PATCHED_FLAVORS)
        self.assertIn('orbit-engine-extensions-r24', x2.PATCHED_FLAVORS)


if __name__ == '__main__':
    unittest.main()
