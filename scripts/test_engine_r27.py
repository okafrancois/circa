"""Offline checks of the r27 pins: the r26 composition plus action.openPopup() for hosted Browsers; no source tree or build is touched."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'native/OrbitChromium/cef-patches'


def files(patch):
    return re.findall(r'^\+\+\+ b/(\S+)', patch, re.M)


def added(patch):
    return ''.join(line[1:] + '\n' for line in patch.splitlines() if line.startswith('+') and not line.startswith('+++'))


def removed(patch):
    return [line for line in patch.splitlines() if line.startswith('-') and not line.startswith('---')]


class EngineR27Tests(unittest.TestCase):
    def setUp(self):
        self.pins = json.loads((PATCHES / 'engine-r27/source.json').read_text())
        self.r26 = json.loads((PATCHES / 'engine-r26/source.json').read_text())
        self.chromium = (PATCHES / 'engine-r27' / self.pins['chromium_delta_patch']).read_text()
        self.cef = (PATCHES / 'engine-r27' / self.pins['cef_delta_patch']).read_text()
        self.cef_source = added(self.cef)

    def test_same_release_as_r26(self):
        self.assertEqual(self.pins['flavor'], 'orbit-engine-extensions-r27')
        self.assertEqual(self.pins['previous_flavor'], self.r26['flavor'])
        self.assertEqual(self.pins['union_from'], 'engine-r26')
        for key in ('chromium_tag', 'chromium_commit', 'previous_chromium_tag', 'previous_chromium_commit',
                    'cef_branch', 'cef_base', 'cef_tree', 'dependencies', 'depot_tools', 'cef_patch_sha256',
                    'chromium_patch_sha256', 'side_api_version', 'webauthn_keychain_access_group'):
            self.assertEqual(self.pins[key], self.r26[key], key)
        self.assertEqual(self.pins['side_api_version'], 19)

    def test_r26_composition_is_carried_unchanged(self):
        previous = self.pins['previous_deltas']
        self.assertEqual({key: value for key, value in previous.items() if key != 'r26'}, self.r26['previous_deltas'])
        self.assertEqual(previous['r26'], {'patch': 'engine-r26/' + self.r26['chromium_delta_patch'],
                                           'sha256': self.r26['chromium_delta_patch_sha256']})
        for delta in (previous['r22'], previous['r23'], previous['r24']['chromium'], previous['r24']['cef'],
                      previous['r26']):
            self.assertEqual(hashlib.sha256((PATCHES / delta['patch']).read_bytes()).hexdigest(), delta['sha256'])
        for name in ('cef', 'chromium'):
            data = (PATCHES / 'engine-r21' / (name + '.patch')).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), self.pins[name + '_patch_sha256'])

    def test_chromium_delta_is_only_the_open_popup_hook(self):
        path = PATCHES / 'engine-r27' / self.pins['chromium_delta_patch']
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), self.pins['chromium_delta_patch_sha256'])
        self.assertEqual(files(self.chromium), ['chrome/browser/extensions/api/extension_action/extension_action_api.cc'])
        self.assertEqual(removed(self.chromium), [])
        self.assertIn('+#if BUILDFLAG(ENABLE_CEF) && BUILDFLAG(IS_MAC)\n'
                      '+#include "cef/libcef/browser/orbit/orbit_action_popup.h"\n', self.chromium)
        self.assertIn('+          orbit::OpenHostedActionPopup(browser, extension, callback, error)) {\n'
                      '+    return *hosted;\n', self.chromium)
        # No earlier patch touches the hooked file, so every delta stays independently checkable.
        earlier = [PATCHES / 'engine-r21/chromium.patch', PATCHES / self.pins['previous_deltas']['r22']['patch'],
                   PATCHES / self.pins['previous_deltas']['r23']['patch'],
                   PATCHES / self.pins['previous_deltas']['r24']['chromium']['patch'],
                   PATCHES / self.pins['previous_deltas']['r26']['patch']]
        for patch in earlier:
            self.assertNotIn(files(self.chromium)[0], files(patch.read_text()), patch.name)

    def test_cef_delta_adds_the_hosted_popup_service_without_a_side_api_change(self):
        path = PATCHES / 'engine-r27' / self.pins['cef_delta_patch']
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), self.pins['cef_delta_patch_sha256'])
        self.assertEqual(files(self.cef), ['libcef/browser/orbit/orbit_cef_api.mm',
                                           'libcef/browser/orbit/orbit_action_popup.h',
                                           'libcef/browser/orbit/orbit_action_popup.inc'])
        self.assertEqual(removed(self.cef), [])
        # Appended after the toolbar services, outside the r24 CEF delta's hunks of the same file.
        self.assertIn(' #include "cef/libcef/browser/orbit/orbit_extension_toolbar.inc"\n'
                      '+// chrome.action.openPopup() in hosted logical Browsers.\n'
                      '+#include "cef/libcef/browser/orbit/orbit_action_popup.inc"\n', self.cef)
        self.assertNotIn('orbit_cef_api.h', files(self.cef))
        for text in ('extern "C" CEF_EXPORT int32_t orbit_cef_extension_popup_observe(',
                     'extern "C" CEF_EXPORT int32_t orbit_cef_extension_open_popup(',
                     'std::optional<bool> OpenHostedActionPopup(BrowserWindowInterface& window_interface,',
                     # The API path never runs the action: no RunAction, so no activeTab grant.
                     'constexpr char kOpenPopupFailed[] = "Failed to open popup.";',
                     'browser->GetProfile()->IsOffTheRecord()',
                     'WindowHasExtensionPopup(window)',
                     'ExtensionPopup::ShowPopupWithNativeParent(browser, std::move(popup_host),'):
            self.assertIn(text, self.cef_source)
        self.assertNotIn('RunAction', self.cef_source)

    def test_bridge_resolves_the_exported_functions(self):
        bridge = (ROOT / 'native/OrbitChromium/Bridge/OrbitChromiumBridge.mm').read_text()
        self.assertIn('"orbit_cef_extension_open_popup"', bridge)
        self.assertIn('"orbit_cef_extension_popup_observe"', bridge)
        self.assertIn('int32_t (*extension_popup_observe)(void (*)(void*, int32_t, const char*, uint64_t), void*)', bridge)
        self.assertIn('int32_t (*extension_open_popup)(uint64_t, void*, uint64_t, uint64_t, uint64_t, uint64_t)', bridge)
        self.assertIn('using orbit_popup_request_t = void (*)(void* context, int32_t browser_id,\n'
                      '                                       const char* extension_id, uint64_t request);', self.cef_source)
        self.assertIn('int32_t orbit_cef_extension_open_popup(uint64_t request, void* anchor_nsview,\n'
                      '    uint64_t invocation, uint64_t surface_token, uint64_t profile_token, uint64_t selection_epoch)',
                      self.cef_source)

    def test_release_carries_the_r27_popup_deltas(self):
        config = json.loads((ROOT / 'release/config.json').read_text())
        engine = json.loads((ROOT / 'release/engine.json').read_text())
        self.assertEqual(config['cef_flavor'], engine['flavor'])
        number = int(engine['flavor'].rsplit('-r', 1)[1])
        self.assertGreaterEqual(number, 27)
        current = json.loads((PATCHES / ('engine-r%d/source.json' % number)).read_text())
        for key in ('chromium_delta_patch_sha256', 'cef_delta_patch_sha256'):
            self.assertEqual(current[key], self.pins[key])
        self.assertEqual(engine['url'], 'https://github.com/okafrancois/circa/releases/download/engine-r%d/'
                                        'orbit-engine-extensions-r%d.tar.gz' % (number, number))
        for key in ('archive_sha256', 'framework_sha256', 'wrapper_sha256'):
            self.assertRegex(engine[key], r'^[0-9a-f]{64}$')

    def test_builder_and_flavor_registry(self):
        builder = (ROOT / 'scripts/cef-engine-r27-build.py').read_text()
        self.assertIn("FLAVOR = 'orbit-engine-extensions-r27'", builder)
        self.assertIn('WRAPPER_API_VERSION = r26.WRAPPER_API_VERSION', builder)
        self.assertIn('r25.check_pins(pins)', builder)
        self.assertIn("b'orbit_cef_extension_popup_observe'", builder)
        spec = importlib.util.spec_from_file_location('x2_r27', ROOT / 'scripts/orbit-chromium-x2.py')
        x2 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(x2)
        for flavor in ('orbit-engine-extensions-r25', 'orbit-engine-extensions-r26', 'orbit-engine-extensions-r27'):
            self.assertIn(flavor, x2.PATCHED_FLAVORS)
        self.assertEqual(sorted(p.name for p in (PATCHES / 'engine-r27').iterdir()),
                         ['README.md', 'cef-delta.patch', 'chromium-delta.patch', 'source.json'])


if __name__ == '__main__':
    unittest.main()
