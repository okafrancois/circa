"""Offline packaging defaults; no signing, installation or application launch."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
from orbit_bundle_policy import validate_bundle_contents
spec = importlib.util.spec_from_file_location('orbit_app', Path(__file__).with_name('orbit-app.py'))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


class SyntheticDefaultTests(unittest.TestCase):
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
