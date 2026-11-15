"""Offline checks of the r24 pins, its two deltas and side API v19; no source tree or build is touched."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'native/OrbitChromium/cef-patches'
BRIDGE = ROOT / 'native/OrbitChromium/Bridge'


def added_lines(patch):
    return '\n'.join(line[1:] for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++'))


def patched_files(patch):
    return re.findall(r'^\+\+\+ b/(\S+)', patch, re.M)


class EngineR24Tests(unittest.TestCase):
    def setUp(self):
        self.pins = json.loads((PATCHES / 'engine-r24/source.json').read_text())
        self.r23 = json.loads((PATCHES / 'engine-r23/source.json').read_text())
        self.chromium = (PATCHES / 'engine-r24' / self.pins['chromium_delta_patch']).read_text()
        self.cef = (PATCHES / 'engine-r24' / self.pins['cef_delta_patch']).read_text()

    def test_r23_composition_is_carried_unchanged(self):
        self.assertEqual(self.pins['flavor'], 'orbit-engine-extensions-r24')
        self.assertEqual(self.pins['previous_flavor'], 'orbit-engine-extensions-r23')
        self.assertEqual(self.pins['union_from'], 'engine-r23')
        for key in ('chromium_tag', 'chromium_commit', 'cef_branch', 'cef_base', 'cef_tree', 'dependencies',
                    'depot_tools', 'cef_patch_sha256', 'chromium_patch_sha256', 'webauthn_keychain_access_group'):
            self.assertEqual(self.pins[key], self.r23[key], key)
        previous = self.pins['previous_deltas']
        self.assertEqual(previous['r22'], {'patch': self.r23['previous_delta_patch'],
                                           'sha256': self.r23['previous_delta_patch_sha256']})
        self.assertEqual(previous['r23'], {'patch': 'engine-r23/' + self.r23['delta_patch'],
                                           'sha256': self.r23['delta_patch_sha256']})
        for delta in previous.values():
            self.assertEqual(hashlib.sha256((PATCHES / delta['patch']).read_bytes()).hexdigest(), delta['sha256'])

    def test_delta_checksums(self):
        self.assertEqual(hashlib.sha256(self.chromium.encode()).hexdigest(), self.pins['chromium_delta_patch_sha256'])
        self.assertEqual(hashlib.sha256(self.cef.encode()).hexdigest(), self.pins['cef_delta_patch_sha256'])

    def test_chromium_delta_avoids_broad_rebuilds(self):
        files = patched_files(self.chromium)
        self.assertEqual(sorted(files), [
            'chrome/browser/extensions/chrome_browser_context_lifetime_tracker.cc',
            'chrome/browser/extensions/component_loader.cc',
            'content/browser/media/audio_output_stream_broker.cc',
            'extensions/browser/api/cookies/cookies_api.cc',
            'extensions/browser/api/cookies/cookies_api.h',
            'extensions/browser/browser_context_lifetime_observer.h'])
        # No mojom, build file or widely included header (the whole delta rebuilds in minutes).
        self.assertFalse([f for f in files if f.endswith(('.mojom', '.gn', '.gni'))])

    def test_side_api_v19_is_additive(self):
        header = (BRIDGE / 'OrbitCefApi.h').read_text()
        self.assertIn('#define ORBIT_CEF_API_VERSION %du' % self.pins['side_api_version'], header)
        self.assertEqual(self.pins['side_api_version'], 19)
        tail = header.split('int32_t (*devtools_focus)(int32_t);')[1]
        for member in ('extension_action_detached', 'tab_volume_set', 'tab_volume_get', 'content_blocking_configure'):
            self.assertIn('(*%s)' % member, tail)
        # The bridge copy is the engine header verbatim.
        engine_header = re.search(r'^\+\+\+ b/libcef/browser/orbit/orbit_cef_api.h', self.cef, re.M)
        self.assertIsNotNone(engine_header)
        bridge = (BRIDGE / 'OrbitChromiumBridge.mm').read_text()
        self.assertIn('{19u, sizeof(orbit_cef_api_t)}', bridge)
        self.assertIn('{18u, offsetof(orbit_cef_api_t, extension_action_detached)}', bridge)

    def test_cef_delta_wires_every_v19_entry(self):
        added = added_lines(self.cef)
        for name in ('ExtensionActionDetached', 'TabVolumeSet', 'TabVolumeGet', 'ContentBlockingConfigure'):
            self.assertIn('= &%s;' % name, added)
        self.assertIn('case 19u:', added)
        self.assertIn('extensions::ServiceWorkerTaskQueue::Get(otr_profile);', added)
        self.assertIn('DetachedExtensionWindowDestroyed(window_token);', added)
        # Placement: 40 pt right and 10 pt below the source window's top-left corner.
        self.assertIn('kDetachedPopupOffset(40, 10)', added)

    def test_component_switch_is_shared_and_bridge_only(self):
        policy = (BRIDGE / 'OrbitBridgePolicy.h').read_text()
        switch = re.search(r'kComponentExtensionSwitch\[\] = "([^"]+)"', policy)[1]
        self.assertIn('"%s"' % switch, added_lines(self.chromium))
        self.assertIn('"%s"' % switch, added_lines(self.cef))
        builder = (ROOT / 'scripts/cef-engine-r24-build.py').read_text()
        self.assertIn("b'%s'" % switch, builder)

    def test_blocker_has_no_worker_or_cookie_channel(self):
        manifest = json.loads((ROOT / 'native/OrbitChromium/ContentBlocker/manifest.json').read_text())
        self.assertEqual(manifest['permissions'], ['declarativeNetRequest'])
        self.assertFalse({'background', 'host_permissions', 'incognito'} & manifest.keys())
        self.assertFalse((ROOT / 'native/OrbitChromium/ContentBlocker/background.js').exists())
        bridge = (BRIDGE / 'OrbitChromiumBridge.mm').read_text()
        self.assertNotIn('"load-extension",\n          (loaded.empty()', bridge)
        self.assertNotIn('ContentBlockingAckReader', bridge)

    def test_release_points_at_r24(self):
        config = json.loads((ROOT / 'release/config.json').read_text())
        engine = json.loads((ROOT / 'release/engine.json').read_text())
        self.assertEqual(config['cef_flavor'], self.pins['flavor'])
        self.assertEqual(engine['flavor'], self.pins['flavor'])
        self.assertEqual(engine['url'], 'https://github.com/okafrancois/circa/releases/download/engine-r24/'
                                        'orbit-engine-extensions-r24.tar.gz')

    def test_builder_and_flavor_registry(self):
        builder = (ROOT / 'scripts/cef-engine-r24-build.py').read_text()
        self.assertIn("FLAVOR = 'orbit-engine-extensions-r24'", builder)
        cmake = (ROOT / 'native/OrbitChromium/CMakeLists.txt').read_text()
        self.assertEqual(re.search(r"WRAPPER_API_VERSION = '([0-9]+)'", builder)[1],
                         re.search(r'CEF_API_VERSION[^0-9]*([0-9]+)', cmake)[1])
        spec = importlib.util.spec_from_file_location('x2_r24', ROOT / 'scripts/orbit-chromium-x2.py')
        x2 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(x2)
        self.assertIn('orbit-engine-extensions-r24', x2.PATCHED_FLAVORS)
        self.assertIn('orbit-engine-extensions-r23', x2.PATCHED_FLAVORS)


if __name__ == '__main__':
    unittest.main()
