"""Offline packaging defaults; no signing, installation or application launch."""
import importlib.util
from pathlib import Path
import sys
import plistlib
import tempfile
import shutil
import subprocess
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
from orbit_bundle_policy import BRAND_FONT_FILES, HELPERS, set_helper_bundle_identifiers, validate_bundle_contents
spec = importlib.util.spec_from_file_location('orbit_app', Path(__file__).with_name('orbit-app.py'))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


class ResourceAssemblyTests(unittest.TestCase):
    def test_font_allowlist_matches_the_shipped_resources(self):
        directory = Path(__file__).resolve().parents[1] / 'native/Sources/BrowserShell/Resources/BrandFonts'
        self.assertEqual(BRAND_FONT_FILES, frozenset(path.name for path in directory.iterdir() if path.is_file()))

    def test_incremental_assembly_removes_deleted_fonts_icons_and_locales(self):
        script = Path(__file__).resolve().parents[1] / 'native/OrbitChromium/PackageLocalization.cmake'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            english = source / 'en.lproj'
            english.mkdir(parents=True)
            (english / 'Localizable.strings').write_text('"test" = "Test";')
            fonts = source / 'BrandFonts'
            fonts.mkdir()
            removed = fonts / 'removed.ttf'
            removed.write_bytes(b'synthetic removed font')
            bundle = root / 'Shell.bundle'
            def assemble():
                subprocess.run(['cmake', '-DSOURCE=' + str(source), '-DDESTINATION=' + str(bundle),
                                '-P', str(script)], check=True, capture_output=True)
            assemble()
            resources = bundle / 'Contents/Resources'
            (resources / 'Icons').mkdir()
            (resources / 'Icons/removed.pdf').write_bytes(b'synthetic removed icon')
            (resources / 'removed.lproj').mkdir()
            (resources / 'removed.lproj/Localizable.strings').write_text('stale')
            removed.unlink()
            (fonts / 'current.ttf').write_bytes(b'synthetic current font')
            assemble()
            def inventory(directory):
                return {path.relative_to(directory): path.read_bytes() for path in directory.rglob('*') if path.is_file()}
            self.assertEqual(inventory(resources), inventory(source))


class SyntheticDefaultTests(unittest.TestCase):
    def test_packaged_document_types_are_alternate_viewers(self):
        info = app.bundle_info('0.1.0')
        for uti in ('com.adobe.pdf', 'public.html', 'public.xhtml'):
            claim = next(item for item in info['CFBundleDocumentTypes'] if uti in item['LSItemContentTypes'])
            self.assertEqual(claim['CFBundleTypeRole'], 'Viewer')
            self.assertEqual(claim['LSHandlerRank'], 'Alternate')

    def test_download_quarantine_is_enabled_in_templates_and_packaged_metadata(self):
        root = Path(__file__).resolve().parents[1]
        for variant in ('', 'App', 'Smoke'):
            with self.subTest(template=variant):
                info = plistlib.loads((root / 'native/OrbitChromium' / variant / 'Info.plist.in').read_bytes())
                self.assertIs(info.get('LSFileQuarantineEnabled'), True)
        for bundle_id in (app.BUNDLE_ID, app.LIVE_BUNDLE_ID, 'lab.orbit.orbit.synthetic'):
            with self.subTest(bundle_id=bundle_id):
                self.assertIs(app.bundle_info('0.1.0', bundle_id).get('LSFileQuarantineEnabled'), True)

    def test_alert_service_keeps_its_identity_and_presents_the_browser_name_and_icon(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'Orbit.app'
            resources = bundle / 'Contents/Resources'
            resources.mkdir(parents=True)
            (resources / 'Orbit.icns').write_bytes(b'synthetic icon')
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'lab.orbit.orbit.notifications', 'CFBundleName': 'Circa',
                'CFBundleDisplayName': 'Orbit', 'OrbitSyntheticBundle': True}))
            for name in HELPERS:
                contents = bundle / 'Contents/Frameworks' / name / 'Contents'
                contents.mkdir(parents=True)
                (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleName': name[:-4]}))
            set_helper_bundle_identifiers(bundle)
            alert = bundle / 'Contents/Frameworks/Orbit Helper (Alerts).app/Contents'
            info = plistlib.loads((alert / 'Info.plist').read_bytes())
            self.assertEqual(info['CFBundleIdentifier'], 'lab.orbit.orbit.notifications.helper.alerts')
            self.assertEqual(info['CFBundleDisplayName'], 'Circa')
            self.assertEqual(info['NSUserNotificationAlertStyle'], 'alert')
            self.assertEqual((alert / 'Resources' / info['CFBundleIconFile']).read_bytes(), b'synthetic icon')
            validate_bundle_contents(bundle)
            (alert / 'Resources/Unexpected.icns').write_bytes(b'unknown')
            with self.assertRaisesRegex(RuntimeError, 'Unexpected bundle content'):
                validate_bundle_contents(bundle)

    def test_plural_resources_keep_an_exact_file_boundary_in_both_bundle_layouts(self):
        for nested in (True, False):
            with self.subTest(nested=nested), tempfile.TemporaryDirectory() as temporary:
                bundle = Path(temporary) / 'Orbit.app'
                resources = bundle / 'Contents/Resources/OrbitLabNative_BrowserShell.bundle'
                if nested:
                    resources /= 'Contents/Resources'
                locale = resources / 'en.lproj'
                locale.mkdir(parents=True)
                plural = locale / 'Localizable.stringsdict'
                plural.write_text('<plist version="1.0"><dict/></plist>')
                validate_bundle_contents(bundle)
                unknown = plural.with_name('Unrelated.stringsdict')
                plural.rename(unknown)
                with self.assertRaisesRegex(RuntimeError, 'Unexpected bundle content'):
                    validate_bundle_contents(bundle)
                unknown.rename(plural)
                plural.unlink()
                plural.mkdir()
                with self.assertRaisesRegex(RuntimeError, 'Invalid shared localization resource type'):
                    validate_bundle_contents(bundle)
                plural.rmdir()
                target = locale / 'Localizable.strings'
                target.write_text('"Test" = "Test";')
                plural.symlink_to(target.name)
                with self.assertRaisesRegex(RuntimeError, 'Invalid shared localization resource type'):
                    validate_bundle_contents(bundle)

    def test_interface_icons_are_complete_and_bounded_in_both_resource_layouts(self):
        source = Path(__file__).resolve().parents[1] / 'native/Sources/BrowserShell/Icons'
        for nested in (True, False):
            with self.subTest(nested=nested), tempfile.TemporaryDirectory() as temporary:
                bundle = Path(temporary) / 'Orbit.app'
                resources = bundle / 'Contents/Resources/OrbitLabNative_BrowserShell.bundle'
                if nested:
                    resources /= 'Contents/Resources'
                icons = resources / 'Icons'
                shutil.copytree(source, icons)
                validate_bundle_contents(bundle)
                unknown = icons / 'template/16/unlisted.pdf'
                unknown.write_bytes(b'unknown')
                with self.assertRaisesRegex(RuntimeError, 'Unexpected bundle content'):
                    validate_bundle_contents(bundle)
                unknown.unlink()
                required = icons / 'template/20/gearshape.pdf'
                saved = required.read_bytes()
                required.unlink()
                with self.assertRaisesRegex(RuntimeError, 'Missing or invalid required interface icon'):
                    validate_bundle_contents(bundle)
                required.symlink_to('../16/gearshape.pdf')
                with self.assertRaisesRegex(RuntimeError, 'Invalid interface icon resource type'):
                    validate_bundle_contents(bundle)
                required.unlink()
                required.write_bytes(saved)
                validate_bundle_contents(bundle)

    def test_app_icon_choices_are_complete_bounded_and_not_symlinks(self):
        source = Path(__file__).resolve().parents[1] / 'native/Sources/BrowserShell/AppIcons'
        for nested in (True, False):
            with self.subTest(nested=nested), tempfile.TemporaryDirectory() as temporary:
                bundle = Path(temporary) / 'Orbit.app'
                resources = bundle / 'Contents/Resources/OrbitLabNative_BrowserShell.bundle'
                if nested:
                    resources /= 'Contents/Resources'
                icons = resources / 'AppIcons'
                shutil.copytree(source, icons)
                validate_bundle_contents(bundle)
                unknown = icons / 'unlisted.png'
                unknown.write_bytes(b'unknown')
                with self.assertRaisesRegex(RuntimeError, 'Unexpected bundle content'):
                    validate_bundle_contents(bundle)
                unknown.unlink()
                required = icons / 'stage.icns'
                saved = required.read_bytes()
                required.unlink()
                with self.assertRaisesRegex(RuntimeError, 'Missing or invalid required app icon'):
                    validate_bundle_contents(bundle)
                required.symlink_to('paper.icns')
                with self.assertRaisesRegex(RuntimeError, 'Invalid app icon resource type'):
                    validate_bundle_contents(bundle)
                required.unlink()
                required.write_bytes(saved)
                validate_bundle_contents(bundle)

    def test_default_synthetic_identifier_passes_assembly_admission(self):
        class Admitted(Exception):
            pass

        # Stop exactly after identifier admission, before creating a root or copying a bundle.
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(sys, 'argv', ['orbit-app.py', 'build', '--synthetic', '--output',
                                       str(Path(temporary) / 'Orbit.app')]), \
             patch.object(app, 'prepare_synthetic_root', side_effect=Admitted):
            with self.assertRaises(Admitted):
                app.main()


if __name__ == '__main__':
    unittest.main()
