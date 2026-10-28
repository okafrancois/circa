"""Offline packaging defaults; no signing, installation or application launch."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('orbit_app', Path(__file__).with_name('orbit-app.py'))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


class SyntheticDefaultTests(unittest.TestCase):
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
