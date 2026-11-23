"""Offline checks of the r26 pins: the r25 composition plus the UserScriptListener delta; no source tree or build is touched."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'native/OrbitChromium/cef-patches'


class EngineR26Tests(unittest.TestCase):
    def setUp(self):
        self.pins = json.loads((PATCHES / 'engine-r26/source.json').read_text())
        self.r25 = json.loads((PATCHES / 'engine-r25/source.json').read_text())
        self.delta = (PATCHES / 'engine-r26' / self.pins['chromium_delta_patch']).read_text()

    def test_same_release_as_r25(self):
        self.assertEqual(self.pins['flavor'], 'orbit-engine-extensions-r26')
        self.assertEqual(self.pins['previous_flavor'], self.r25['flavor'])
        self.assertEqual(self.pins['union_from'], 'engine-r25')
        for key in ('chromium_tag', 'chromium_commit', 'previous_chromium_tag', 'previous_chromium_commit',
                    'cef_branch', 'cef_base', 'cef_tree', 'dependencies', 'depot_tools', 'cef_patch_sha256',
                    'chromium_patch_sha256', 'side_api_version', 'webauthn_keychain_access_group'):
            self.assertEqual(self.pins[key], self.r25[key], key)

    def test_r25_composition_is_carried_unchanged(self):
        self.assertEqual(self.pins['previous_deltas'], self.r25['previous_deltas'])
        previous = self.pins['previous_deltas']
        for delta in (previous['r22'], previous['r23'], previous['r24']['chromium'], previous['r24']['cef']):
            self.assertEqual(hashlib.sha256((PATCHES / delta['patch']).read_bytes()).hexdigest(), delta['sha256'])
        for name in ('cef', 'chromium'):
            data = (PATCHES / 'engine-r21' / (name + '.patch')).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), self.pins[name + '_patch_sha256'])

    def test_delta_is_the_user_script_listener_fix_and_its_test(self):
        path = PATCHES / 'engine-r26' / self.pins['chromium_delta_patch']
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), self.pins['chromium_delta_patch_sha256'])
        self.assertEqual(re.findall(r'^\+\+\+ b/(\S+)', self.delta, re.M),
                         ['chrome/browser/extensions/user_script_listener.cc',
                          'chrome/browser/extensions/user_script_listener_unittest.cc',
                          'content/public/test/mock_navigation_throttle_registry.cc',
                          'content/public/test/mock_navigation_throttle_registry.h'])
        # The listener fix and its test only add lines; the test-only mock follows the fork's
        # AddThrottle(throttle, first) signature so that the test target compiles.
        files = re.split(r'^diff --git ', self.delta, flags=re.M)[1:]
        for text in files:
            removed = [line for line in text.splitlines() if line.startswith('-') and not line.startswith('---')]
            if text.startswith('a/chrome/'):
                self.assertEqual(removed, [], text.split()[0])
            else:
                self.assertTrue(text.startswith('a/content/public/test/mock_navigation_throttle_registry.'))
                self.assertLessEqual(len(removed), 2)
        self.assertIn('+                   bool first = false) override;', self.delta)
        self.assertIn('+void UserScriptListener::ProfileDestroyed(content::BrowserContext* context) {', self.delta)
        self.assertIn('+  profile_data_.erase(context);\n+  CheckIfAllUserScriptsReady();', self.delta)
        self.assertIn('+  ProfileDestroyed(registry->browser_context());', self.delta)
        self.assertIn('+TEST_F(UserScriptListenerTest, ProfileDestroyedBeforeScriptsReady) {', self.delta)
        self.assertIn('+  profile_manager_->DeleteTestingProfile("test-profile2");\n+  EXPECT_TRUE(was_navigation_resumed_);',
                      self.delta)
        self.assertEqual(sorted(p.name for p in (PATCHES / 'engine-r26').iterdir()),
                         ['README.md', 'source.json', 'user-script-listener-shutdown.patch'])

    def test_release_points_at_r26(self):
        config = json.loads((ROOT / 'release/config.json').read_text())
        engine = json.loads((ROOT / 'release/engine.json').read_text())
        self.assertEqual(config['cef_flavor'], self.pins['flavor'])
        self.assertEqual(engine['flavor'], self.pins['flavor'])
        self.assertEqual(engine['url'], 'https://github.com/okafrancois/circa/releases/download/engine-r26/'
                                        'orbit-engine-extensions-r26.tar.gz')
        for key in ('archive_sha256', 'framework_sha256', 'wrapper_sha256'):
            self.assertRegex(engine[key], r'^[0-9a-f]{64}$')

    def test_builder_and_flavor_registry(self):
        builder = (ROOT / 'scripts/cef-engine-r26-build.py').read_text()
        self.assertIn("FLAVOR = 'orbit-engine-extensions-r26'", builder)
        self.assertIn('WRAPPER_API_VERSION = r25.WRAPPER_API_VERSION', builder)
        self.assertIn('r25.check_pins(pins)', builder)
        spec = importlib.util.spec_from_file_location('x2_r26', ROOT / 'scripts/orbit-chromium-x2.py')
        x2 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(x2)
        self.assertIn('orbit-engine-extensions-r26', x2.PATCHED_FLAVORS)
        self.assertIn('orbit-engine-extensions-r25', x2.PATCHED_FLAVORS)


if __name__ == '__main__':
    unittest.main()
