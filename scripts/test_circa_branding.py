"""Visible branding scan with explicit compatibility exceptions; no application launch."""
from pathlib import Path
import json
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
# Approved macOS exception: raw display name matches Orbit.app; localized name is Circa.
BUNDLE_METADATA_EXCEPTIONS = {'CFBundleDisplayName': 'Orbit'}
# Exact technical literals: persisted identities, resource paths, signing and named colors.
INTERNAL = {
    'Orbit', 'Orbit Native', 'Orbit Live', 'Orbit Live Chromium', 'Orbit Safe Storage',
    'Orbit Live Safe Storage', 'Orbit Lab Local Development', 'Orbit.icns',
    'Orbit.', 'Orbit.ThemeEditor.', 'Orbit.Theme.space.\\(light).\\(dark)',
    'Orbit.Floating.body', 'Orbit.Floating.secondary', 'Orbit.Floating.accentText',
    'Orbit.Conformance.Fixture', 'Orbit.BrowserSessionPersistence',
    'OrbitLiveSessionTool', 'OrbitLiveSessionValidation',
    'Orbit Live Authentication Recovery v1',
    'Orbit password import v1:',
}
TECHNICAL_TOKEN = re.compile(r'^Orbit[A-Za-z0-9_:.-]+$')


class CircaBrandingTests(unittest.TestCase):
    def test_visible_source_and_resources(self):
        failures = []
        for file in (ROOT / 'native/Sources').rglob('*'):
            if file.suffix not in {'.swift', '.strings', '.stringsdict'}:
                continue
            text = file.read_text()
            for line in text.splitlines():
                if line.lstrip().startswith(('//', '/*', '*')):
                    continue
                for literal in re.findall(r'"([^"\n]*)"', line):
                    if not re.search(r'\bOrbit\b', literal):
                        continue
                    # Localization tables never admit compatibility exceptions.
                    if file.suffix == '.swift' and (literal in INTERNAL or TECHNICAL_TOKEN.fullmatch(literal)):
                        continue
                    failures.append(f'{file.relative_to(ROOT)}: {literal}')
        self.assertEqual(failures, [])

    def test_display_name_and_compatibility_metadata(self):
        import product_identity
        self.assertEqual(product_identity.DISPLAY_NAME, 'Circa')
        self.assertEqual(product_identity.PRODUCT_NAME, 'Orbit')
        self.assertEqual(product_identity.BUNDLE_ID, 'io.github.okatech.orbit')
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location('packager', ROOT / 'scripts/orbit-app.py')
        app = module_from_spec(spec)
        spec.loader.exec_module(app)
        config = json.loads((ROOT / 'release/config.json').read_text())
        self.assertEqual(config['name'], 'Circa')
        for identifier in [app.BUNDLE_ID, app.LIVE_BUNDLE_ID, 'lab.orbit.orbit.synthetic']:
            info = app.bundle_info('0.1.0', identifier)
            self.assertEqual(info['CFBundleName'], 'Circa')
            # Raw display name must match Orbit.app so Finder uses localized Circa.
            self.assertEqual(info['CFBundleDisplayName'], BUNDLE_METADATA_EXCEPTIONS['CFBundleDisplayName'])
            self.assertTrue(info['LSHasLocalizedDisplayName'])
            self.assertEqual(info['CFBundleIdentifier'], identifier)
            self.assertEqual(info['CFBundleExecutable'], 'Orbit')
            from update_feed import update_feed_url
            self.assertEqual(info['SUFeedURL'], update_feed_url(config['repository']))
            self.assertEqual(info['SUPublicEDKey'], config['public_ed_key'])
        template = plistlib.loads((ROOT / 'native/OrbitChromium/App/Info.plist.in').read_bytes())
        self.assertEqual(template['CFBundleName'], 'Circa')
        # Approved exception to the visible-name scan: raw display metadata only.
        self.assertEqual(template['CFBundleDisplayName'], BUNDLE_METADATA_EXCEPTIONS['CFBundleDisplayName'])
        self.assertTrue(template['LSHasLocalizedDisplayName'])
        for file in (ROOT / 'native/OrbitChromium/App/Branding').glob('*.lproj/InfoPlist.strings'):
            self.assertEqual(plistlib.loads(file.read_bytes())['CFBundleDisplayName'], 'Circa')
        identity = product_identity.IDENTITY
        self.assertEqual(identity['dataDirectoryName'], 'Orbit')
        self.assertEqual(identity['keychainAccount'], 'Orbit')
        self.assertEqual(identity['keychainService'], 'Orbit Safe Storage')

    def test_little_name_and_font_inventory(self):
        resources = ROOT / 'native/Sources/BrowserShell/Resources'
        table = (resources / 'en.lproj/Localizable.strings').read_text()
        self.assertIn('"Open Little Circa from other apps"', table)
        self.assertIn('"New Little Circa Window"', table)
        self.assertNotIn('Little Orbit', table)
        self.assertEqual({file.name for file in (resources / 'BrandFonts').iterdir()}, {'mark.pdf'})
        self.assertFalse(any(file.suffix in {'.ttf', '.otf'} for file in resources.rglob('*')))


if __name__ == '__main__':
    unittest.main()
