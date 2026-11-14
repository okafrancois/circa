"""Offline checks of the r22 pins and its OSCrypt delta; no source tree or build is touched."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'native/OrbitChromium/cef-patches'


class EngineR22Tests(unittest.TestCase):
    def setUp(self):
        self.pins = json.loads((PATCHES / 'engine-r22/source.json').read_text())
        self.r21 = json.loads((PATCHES / 'engine-r21/source.json').read_text())

    def test_r21_union_is_carried_unchanged(self):
        self.assertEqual(self.pins['flavor'], 'orbit-engine-extensions-r22')
        self.assertEqual(self.pins['previous_flavor'], 'orbit-engine-extensions-r21')
        self.assertEqual(self.pins['union_from'], 'engine-r21')
        for key in ('chromium_tag', 'chromium_commit', 'cef_branch', 'cef_base', 'cef_tree', 'dependencies',
                    'depot_tools', 'side_api_version', 'cef_patch_sha256', 'chromium_patch_sha256'):
            self.assertEqual(self.pins[key], self.r21[key], key)
        for name in ('cef', 'chromium'):
            data = (PATCHES / 'engine-r21' / (name + '.patch')).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), self.pins[name + '_patch_sha256'], name)

    def test_delta_keeps_v10_only_in_the_owned_directory(self):
        delta = (PATCHES / 'engine-r22' / self.pins['delta_patch']).read_text()
        self.assertEqual(hashlib.sha256(delta.encode()).hexdigest(), self.pins['delta_patch_sha256'])
        files = re.findall(r'^diff --git a/(\S+) ', delta, re.M)
        self.assertEqual(files, ['chrome/browser/browser_process_impl.cc'])
        added = '\n'.join(line[1:] for line in delta.splitlines() if line.startswith('+') and not line.startswith('+++'))
        self.assertIn('"orbit-owned-user-data-dir"', added)
        self.assertIn('chrome::DIR_USER_DATA', added)
        self.assertIn('std::make_unique<os_crypt_async::KeychainKeyProvider>()', added)
        # Other directories keep the upstream unavailable v10 provider; v11 stays the writer.
        self.assertIn('std::make_unique<UnavailableKeyProvider>("v10")', added)
        removed = [line for line in delta.splitlines() if line.startswith('-') and not line.startswith('---')]
        self.assertFalse(any('"v11"' in line or 'pepper' in line or '15u' in line for line in removed))
        self.assertFalse(re.search(r'kKeychainKeyProviderUserDataDirProtection', added))

    def test_switch_name_matches_the_bridge(self):
        policy = (ROOT / 'native/OrbitChromium/Bridge/OrbitBridgePolicy.h').read_text()
        self.assertIn('kOwnedUserDataDirSwitch[] = "orbit-owned-user-data-dir"', policy)
        bridge = (ROOT / 'native/OrbitChromium/Bridge/OrbitChromiumBridge.mm').read_text()
        self.assertIn('AppendSwitchWithValue(orbit_bridge::kOwnedUserDataDirSwitch, g_state->root)', bridge)

    def test_builder_and_flavor_registry(self):
        builder = (ROOT / 'scripts/cef-engine-r22-build.py').read_text()
        self.assertIn("FLAVOR = 'orbit-engine-extensions-r22'", builder)
        self.assertEqual(re.search(r"WRAPPER_API_VERSION = '([0-9]+)'", builder)[1],
                         re.search(r"WRAPPER_API_VERSION = '([0-9]+)'",
                                   (ROOT / 'scripts/cef-engine-r21-build.py').read_text())[1])
        spec = importlib.util.spec_from_file_location('x2_r22', ROOT / 'scripts/orbit-chromium-x2.py')
        x2 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(x2)
        self.assertIn('orbit-engine-extensions-r22', x2.PATCHED_FLAVORS)


if __name__ == '__main__':
    unittest.main()
