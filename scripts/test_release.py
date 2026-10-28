"""Offline release policy checks; no signing services, app launches or network calls."""
import importlib.util
from pathlib import Path
import sys
import unittest
import json
import os
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import release
import local_signing


class ReleaseTests(unittest.TestCase):
    config = {'name': 'Orbit', 'bundle_id': 'io.github.okatech.orbit',
              'repository': 'okafrancois/orbit-browser', 'public_ed_key': ''}

    def test_local_signing_preserves_the_existing_directory_and_keychain(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            directory = home / '.local/share/previous-product/signing'
            directory.mkdir(parents=True)
            (directory / 'identity.json').write_text(json.dumps({'version': 1, 'fingerprint': 'A' * 40}))
            (directory / 'keychain-password').write_text('synthetic-pass')
            keychain = directory / 'previous-signing.keychain-db'
            keychain.touch()
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(local_signing.signing_directory(home), directory)
            before = sorted(p.name for p in directory.iterdir())
            selected, _, fingerprint = local_signing.identity(directory)
            self.assertEqual(selected, keychain)
            self.assertEqual(fingerprint, 'A' * 40)
            self.assertEqual(sorted(p.name for p in directory.iterdir()), before)

    def test_versions_are_semantic_and_builds_are_numeric(self):
        self.assertEqual(release.release_version('v0.1.0'), '0.1.0')
        for tag in ['0.1.0', 'v1.2', 'v1.2.3-rc1', 'main']:
            with self.assertRaises(ValueError):
                release.release_version(tag)
        info = release.update_info({}, self.config, '0.1.0', 123)
        self.assertEqual(info['CFBundleVersion'], '123')
        self.assertEqual(info['CFBundleShortVersionString'], '0.1.0')
        self.assertEqual(info['SUScheduledCheckInterval'], 3600)
        self.assertTrue(info['SUAutomaticallyUpdate'])

    def test_synthetic_roots_do_not_leak_into_product(self):
        info = release.update_info({'OrbitDataRoot': '/tmp/test', 'OrbitSyntheticBundle': True,
                                    'OrbitUseMockKeychain': True, 'OrbitUpdaterLocalTest': True},
                                   self.config, '0.1.0', 123)
        self.assertFalse(any(key in info for key in ['OrbitDataRoot', 'OrbitSyntheticBundle', 'OrbitUseMockKeychain', 'OrbitUpdaterLocalTest']))

    def test_unicode_identity_uses_its_exact_fingerprint(self):
        name = 'Developer ID Application: Berny François Itoutou (5Y39TTNCM7)'
        fingerprint = 'A' * 40
        listing = ('  1) ' + fingerprint + ' "' + name + '"\n').encode('utf-8')
        with patch.object(local_signing, 'run', return_value=listing):
            with local_signing.configured_identity(name) as arguments:
                self.assertEqual(arguments, ['--sign', fingerprint, '--timestamp'])

    def test_missing_notary_profile_fails_before_building(self):
        config = dict(self.config, identity='Developer ID Application: Test (5Y39TTNCM7)',
                      team_id='5Y39TTNCM7', notarytool_profile='orbit-notary')
        with patch.object(release.subprocess, 'run', return_value=SimpleNamespace(returncode=1)):
            with self.assertRaisesRegex(RuntimeError, "profile 'orbit-notary' is missing"):
                release.require_notary_profile(config)

    def test_test_feed_is_confined(self):
        config = dict(self.config, bundle_id='io.github.okatech.orbit.test.update')
        info = release.update_info({}, config, '0.0.1', 1, Path('/tmp/test'), 'http://127.0.0.1:12345/appcast.xml')
        self.assertTrue(info['OrbitUseMockKeychain'])
        for feed in ['https://example.com/appcast.xml', 'http://localhost:12/appcast.xml']:
            with self.assertRaises(ValueError):
                release.update_info({}, config, '0.0.1', 1, Path('/tmp/test'), feed)
        with self.assertRaises(ValueError):
            release.update_info({}, self.config, '0.1.0', 1, None, 'http://127.0.0.1:123/appcast.xml')


if __name__ == '__main__':
    unittest.main()
