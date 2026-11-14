"""Offline checks of the r21 milestone pins; no source tree or build is touched."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'native/OrbitChromium/cef-patches'


class EngineR21Tests(unittest.TestCase):
    def setUp(self):
        self.pins = json.loads((PATCHES / 'engine-r21/source.json').read_text())

    def test_pins_and_patch_fingerprints(self):
        pins = self.pins
        self.assertRegex(pins['chromium_tag'], r'^158\.0\.8127\.[0-9]+$')
        for key in ('chromium_commit', 'cef_base', 'cef_tree', 'depot_tools'):
            self.assertRegex(pins[key], r'^[0-9a-f]{40}$', key)
        self.assertEqual(pins['flavor'], 'orbit-engine-extensions-r21')
        self.assertEqual(pins['previous_flavor'], 'orbit-engine-extensions-r20')
        self.assertEqual(pins['side_api_version'], 18)
        r20 = json.loads((PATCHES / 'engine-r20/source.json').read_text())
        self.assertEqual(set(pins['dependencies']), set(r20['dependencies']))
        self.assertTrue(all(re.fullmatch(r'[0-9a-f]{40}', v) for v in pins['dependencies'].values()))
        for name in ('cef', 'chromium'):
            data = (PATCHES / 'engine-r21' / (name + '.patch')).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), pins[name + '_patch_sha256'], name)

    def test_union_contents_are_carried(self):
        cef = (PATCHES / 'engine-r21/cef.patch').read_text(errors='replace')
        for marker in ('libcef/browser/orbit/orbit_cef_api.mm', 'patch/patches/orbit_extension_popup.patch',
                       'patch/patches/orbit_ext_window.patch', 'libcef/browser/orbit/orbit_devtools.inc',
                       'libcef/browser/browser_info_manager.cc', 'FILE_DIALOG_OPEN_EXISTING_FOLDER'):
            self.assertIn(marker, cef)
        chromium = (PATCHES / 'engine-r21/chromium.patch').read_text(errors='replace')
        for marker in ('chrome/browser/devtools/devtools_window.cc', 'DeleteSoon(',
                       'components/remote_cocoa/app_shim/appkit_modal_parent.mm',
                       'chrome/browser/ui/navigator/orbit_navigate_intent.h'):
            self.assertIn(marker, chromium)

    def test_wrapper_api_version_matches_the_application(self):
        builder = (ROOT / 'scripts/cef-engine-r21-build.py').read_text()
        wrapper = re.search(r"WRAPPER_API_VERSION = '([0-9]+)'", builder)[1]
        cmake = (ROOT / 'native/OrbitChromium/CMakeLists.txt').read_text()
        versions = set(re.findall(r'CEF_API_VERSION=([0-9]+)', cmake))
        self.assertEqual(versions, {wrapper})
        spec = importlib.util.spec_from_file_location('x2_r21', ROOT / 'scripts/orbit-chromium-x2.py')
        x2 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(x2)
        self.assertIn('orbit-engine-extensions-r21', x2.PATCHED_FLAVORS)


if __name__ == '__main__':
    unittest.main()
