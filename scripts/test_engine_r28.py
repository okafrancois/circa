"""Offline security-roll composition checks; no shared source mutation or GUI."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'native/OrbitChromium/cef-patches'


class EngineR28Tests(unittest.TestCase):
    def test_complete_r27_union_and_native_contract_are_preserved(self):
        old = json.loads((PATCHES / 'engine-r27/source.json').read_text())
        new = json.loads((PATCHES / 'engine-r28/source.json').read_text())
        for key in ('cef_base', 'cef_tree', 'cef_branch', 'cef_patch_sha256',
                    'chromium_patch_sha256', 'previous_deltas', 'chromium_delta_patch',
                    'chromium_delta_patch_sha256', 'cef_delta_patch', 'cef_delta_patch_sha256',
                    'depot_tools', 'side_api_version', 'webauthn_keychain_access_group'):
            self.assertEqual(new[key], old[key], key)
        self.assertEqual(new['side_api_version'], 19)
        self.assertEqual(new['previous_chromium_commit'], old['chromium_commit'])
        self.assertEqual(new['previous_chromium_tag'], old['chromium_tag'])
        self.assertEqual(new['previous_flavor'], old['flavor'])
        self.assertEqual(new['union_from'], 'engine-r27')
        self.assertEqual(new['chromium_tag'], '158.0.8127.90')
        self.assertNotEqual(new['chromium_commit'], old['chromium_commit'])
        self.assertLessEqual(set(old['dependencies']), set(new['dependencies']))
        for name in ('chromium', 'cef'):
            patch = PATCHES / 'engine-r27' / new[name + '_delta_patch']
            self.assertEqual(hashlib.sha256(patch.read_bytes()).hexdigest(),
                             new[name + '_delta_patch_sha256'])

    def test_builder_checks_every_previous_delta_on_rolled_sources(self):
        spec = importlib.util.spec_from_file_location('r28_test', ROOT / 'scripts/cef-engine-r28-build.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.FRAMEWORK_MARKERS, module.r27.FRAMEWORK_MARKERS)
        self.assertEqual(module.WRAPPER_API_VERSION, module.r27.WRAPPER_API_VERSION)
        self.assertIn(module.FLAVOR, module.x2.PATCHED_FLAVORS)
        # Exercise the gate itself: an absent popup delta must prevent compilation/export.
        from unittest.mock import patch
        pins = {'synthetic': True}
        with patch.object(module.r27, 'check_r26') as earlier, \
                patch.object(module.r27, 'delta_states', return_value=('applied', 'not-applied')):
            with self.assertRaises(SystemExit):
                module.check_r27(pins)
            earlier.assert_called_once_with(pins)
        with patch.object(module.r27, 'check_r26'), \
                patch.object(module.r27, 'delta_states', return_value=('applied', 'applied')):
            module.check_r27(pins)


if __name__ == '__main__':
    unittest.main()
