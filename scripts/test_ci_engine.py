"""Engine download admission; no network, signing or application launch."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from ci_engine import install


@unittest.skipUnless(hasattr(tarfile, 'data_filter'), 'CI engine extraction requires Python 3.12+')
class EngineAdmissionTests(unittest.TestCase):
    def fixture(self, root, *, escape=False, wrong_binary=False):
        flavor = 'orbit-engine-extensions-fixture'
        content = b'synthetic engine'
        digest = hashlib.sha256(content).hexdigest()
        descriptor = dict(flavor=flavor, framework_sha256=digest, wrapper_sha256=digest)
        manifest = dict(descriptor, root='cef_binary_fixture_macosarm64_minimal')
        files = {
            flavor + '/manifest.json': json.dumps(manifest).encode(),
            flavor + '/' + manifest['root'] + '/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework': b'wrong' if wrong_binary else content,
            flavor + '/wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a': content,
        }
        if escape:
            files[flavor + '/../../escaped'] = b'refused'
        archive = root / 'engine.tar.gz'
        with tarfile.open(archive, 'w:gz') as bundle:
            for name, data in files.items():
                item = tarfile.TarInfo(name)
                item.size = len(data)
                bundle.addfile(item, io.BytesIO(data))
        descriptor['archive_sha256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
        return archive, descriptor

    def test_install_relocates_manifest_without_replacing_existing_distribution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, descriptor = self.fixture(root)
            target = install(archive, descriptor, root / 'distrib')
            manifest = json.loads((target / 'manifest.json').read_text())
            self.assertEqual(Path(manifest['root']).parent, target)
            with self.assertRaises(ValueError):
                install(archive, descriptor, root / 'distrib')

    def test_archive_and_binary_checksums_are_independently_verified(self):
        for wrong_binary in (False, True):
            with self.subTest(wrong_binary=wrong_binary), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive, descriptor = self.fixture(root, wrong_binary=wrong_binary)
                if not wrong_binary:
                    descriptor['archive_sha256'] = '0' * 64
                with self.assertRaises(ValueError):
                    install(archive, descriptor, root / 'distrib')
                self.assertFalse((root / 'distrib' / descriptor['flavor']).exists())

    def test_parent_traversal_is_refused_without_creating_an_outside_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, descriptor = self.fixture(root, escape=True)
            with self.assertRaises(tarfile.FilterError):
                install(archive, descriptor, root / 'distrib')
            self.assertFalse((root / 'escaped').exists())


if __name__ == '__main__':
    unittest.main()
