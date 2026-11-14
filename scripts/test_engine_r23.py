"""Offline checks of the r23 pins and its system passkeys delta; no source tree or build is touched."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'native/OrbitChromium/cef-patches'
GROUP = '5Y39TTNCM7.io.github.okatech.orbit.webauthn'


def added_lines(patch):
    return '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++'))


def removed_lines(patch):
    return '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('-') and not line.startswith('---'))


class EngineR23Tests(unittest.TestCase):
    def setUp(self):
        self.pins = json.loads((PATCHES / 'engine-r23/source.json').read_text())
        self.r22 = json.loads((PATCHES / 'engine-r22/source.json').read_text())
        self.delta = (PATCHES / 'engine-r23' / self.pins['delta_patch']).read_text()

    def test_r22_composition_is_carried_unchanged(self):
        self.assertEqual(self.pins['flavor'], 'orbit-engine-extensions-r23')
        self.assertEqual(self.pins['previous_flavor'], 'orbit-engine-extensions-r22')
        self.assertEqual(self.pins['union_from'], 'engine-r22')
        for key in ('chromium_tag', 'chromium_commit', 'cef_branch', 'cef_base', 'cef_tree', 'dependencies',
                    'depot_tools', 'side_api_version', 'cef_patch_sha256', 'chromium_patch_sha256'):
            self.assertEqual(self.pins[key], self.r22[key], key)
        for name in ('cef', 'chromium'):
            data = (PATCHES / 'engine-r21' / (name + '.patch')).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), self.pins[name + '_patch_sha256'], name)
        previous = PATCHES / self.pins['previous_delta_patch']
        self.assertEqual(self.pins['previous_delta_patch'], 'engine-r22/' + self.r22['delta_patch'])
        self.assertEqual(hashlib.sha256(previous.read_bytes()).hexdigest(), self.pins['previous_delta_patch_sha256'])
        self.assertEqual(self.pins['previous_delta_patch_sha256'], self.r22['delta_patch_sha256'])

    def test_delta_is_limited_to_the_two_passkey_paths(self):
        self.assertEqual(hashlib.sha256(self.delta.encode()).hexdigest(), self.pins['delta_patch_sha256'])
        files = re.findall(r'^diff --git a/(\S+) ', self.delta, re.M)
        self.assertEqual(files, ['chrome/browser/webauthn/chrome_authenticator_request_delegate.cc',
                                 'chrome/browser/webauthn/chrome_web_authentication_delegate.cc'])
        # No header, mojom or exported API changes: the side API and ABI stay at r22.
        self.assertFalse(re.search(r'^diff --git a/\S+\.(h|mojom|gn|gni) ', self.delta, re.M))

    def test_touch_id_uses_the_signed_team_group(self):
        added, removed = added_lines(self.delta), removed_lines(self.delta)
        self.assertEqual(self.pins['webauthn_keychain_access_group'], GROUP)
        self.assertIn('"%s"' % GROUP, added)
        self.assertIn('MAC_TEAM_IDENTIFIER_STRING "." MAC_BUNDLE_IDENTIFIER_STRING ".webauthn"', removed)
        self.assertNotIn('MAC_BUNDLE_IDENTIFIER_STRING', added)

    def test_hosted_window_fallback_runs_only_without_a_widget(self):
        added, removed = added_lines(self.delta), removed_lines(self.delta)
        self.assertEqual(removed.count('\n'), 0)  # only the Touch ID constant line is replaced
        self.assertIn('web_contents->GetTopLevelNativeWindow()', added)
        self.assertIn('discovery_factory->set_nswindow(hosted_window)', added)
        # The widget branch returns before the fallback, keeping the upstream window choice.
        hunk = self.delta.split('chrome_web_authentication_delegate.cc')[0]
        self.assertLess(hunk.index('+    return;'), hunk.index('GetTopLevelNativeWindow'))
        self.assertIn('if (hosted_window) {', added)

    def test_release_config_matches_the_compiled_group(self):
        config = json.loads((ROOT / 'release/config.json').read_text())
        if 'webauthn_keychain_access_group' not in config:
            return
        self.assertEqual(config['webauthn_keychain_access_group'], GROUP)
        self.assertTrue(GROUP.startswith(config['team_id'] + '.' + config['bundle_id']))
        self.assertGreaterEqual(int(config['cef_flavor'].rsplit('-r', 1)[1]), 23)

    def test_builder_and_flavor_registry(self):
        builder = (ROOT / 'scripts/cef-engine-r23-build.py').read_text()
        self.assertIn("FLAVOR = 'orbit-engine-extensions-r23'", builder)
        cmake = (ROOT / 'native/OrbitChromium/CMakeLists.txt').read_text()
        self.assertEqual(re.search(r"WRAPPER_API_VERSION = '([0-9]+)'", builder)[1],
                         re.search(r'CEF_API_VERSION[^0-9]*([0-9]+)', cmake)[1])
        spec = importlib.util.spec_from_file_location('x2_r23', ROOT / 'scripts/orbit-chromium-x2.py')
        x2 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(x2)
        self.assertIn('orbit-engine-extensions-r23', x2.PATCHED_FLAVORS)


if __name__ == '__main__':
    unittest.main()
