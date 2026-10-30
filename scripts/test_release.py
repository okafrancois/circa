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
    config = {'name': 'Circa', 'bundle_id': 'io.github.okatech.orbit',
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
        self.assertTrue(info['SUAllowsAutomaticUpdates'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertTrue(info['SUAutomaticallyUpdate'])

    def test_release_enables_quarantine_even_for_older_source_bundles(self):
        for source in ({}, {'LSFileQuarantineEnabled': False}):
            with self.subTest(source=source):
                info = release.update_info(source, self.config, '0.1.0', 123)
                self.assertIs(info.get('LSFileQuarantineEnabled'), True)
        config = dict(self.config, bundle_id='io.github.okatech.orbit.test.update')
        info = release.update_info({}, config, '0.1.0', 123, Path('/tmp/test'),
                                   'http://127.0.0.1:12345/appcast.xml')
        self.assertIs(info.get('LSFileQuarantineEnabled'), True)

    def test_feed_requires_the_newest_release_and_a_full_signed_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            feed = Path(temporary) / 'appcast.xml'
            feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
                '<item><sparkle:version>27</sparkle:version><enclosure url="https://example.test/latest.zip" '
                'sparkle:edSignature="test"/><sparkle:deltas><enclosure sparkle:version="999"/></sparkle:deltas></item>'
                '<item><sparkle:version>25</sparkle:version></item></channel></rss>')
            release.validate_appcast(feed, 27)
            with self.assertRaises(ValueError):
                release.validate_appcast(feed, 25)
            feed.write_text(feed.read_text().replace('sparkle:edSignature="test"', ''))
            with self.assertRaises(ValueError):
                release.validate_appcast(feed, 27)

    def test_synthetic_roots_do_not_leak_into_product(self):
        info = release.update_info({'OrbitDataRoot': '/tmp/test', 'OrbitSyntheticBundle': True,
                                    'OrbitUseMockKeychain': True, 'OrbitUpdaterLocalTest': True},
                                   self.config, '0.1.0', 123)
        self.assertFalse(any(key in info for key in ['OrbitDataRoot', 'OrbitSyntheticBundle', 'OrbitUseMockKeychain', 'OrbitUpdaterLocalTest']))
        self.assertEqual(info['CFBundleName'], 'Circa')
        self.assertEqual(info['CFBundleDisplayName'], 'Orbit')
        self.assertTrue(info['LSHasLocalizedDisplayName'])
        self.assertEqual(info['CFBundleIdentifier'], self.config['bundle_id'])

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


class CloudProfileTests(unittest.TestCase):
    config = {'bundle_id': 'io.github.okatech.orbit', 'team_id': '5Y39TTNCM7'}

    def profile(self):
        from datetime import datetime
        return {'ExpirationDate': datetime(2099, 1, 1), 'TeamIdentifier': ['5Y39TTNCM7'],
                'ProvisionsAllDevices': True, 'Entitlements': {
                    'com.apple.developer.icloud-services': ['CloudKit'],
                    'com.apple.developer.icloud-container-identifiers': [release.ICLOUD_CONTAINER],
                    'com.apple.developer.icloud-container-environment': 'Production',
                    'com.apple.application-identifier': '5Y39TTNCM7.io.github.okatech.orbit',
                    'com.apple.developer.team-identifier': '5Y39TTNCM7'}}

    def test_exact_production_profile_with_optional_push(self):
        profile = self.profile()
        expected = release.cloud_entitlements(profile, self.config)
        self.assertEqual(expected, profile['Entitlements'])
        profile['Entitlements']['com.apple.developer.aps-environment'] = 'production'
        self.assertEqual(release.cloud_entitlements(profile, self.config), profile['Entitlements'])
        profile['Entitlements']['com.apple.developer.icloud-container-environment'] = ['Development', 'Production']
        self.assertEqual(release.cloud_entitlements(profile, self.config)['com.apple.developer.icloud-container-environment'], 'Production')

    def test_macos_service_wildcard_requests_only_cloudkit(self):
        for wildcard in ('*', ['*']):
            profile = self.profile()
            profile['Entitlements']['com.apple.developer.icloud-services'] = wildcard
            profile['Entitlements']['com.apple.developer.aps-environment'] = 'production'
            expected = release.cloud_entitlements(profile, self.config)
            self.assertEqual(expected['com.apple.developer.icloud-services'], ['CloudKit'])
            self.assertEqual(expected['com.apple.application-identifier'], '5Y39TTNCM7.io.github.okatech.orbit')
            self.assertEqual(expected['com.apple.developer.aps-environment'], 'production')
        for key in ('com.apple.application-identifier', 'com.apple.developer.icloud-container-identifiers',
                    'com.apple.developer.team-identifier', 'com.apple.developer.icloud-container-environment'):
            profile = self.profile()
            profile['Entitlements'][key] = '*'
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.cloud_entitlements(profile, self.config)

    def test_rejects_mismatched_capabilities_and_distribution(self):
        from datetime import datetime
        for key in self.profile()['Entitlements']:
            profile = self.profile()
            profile['Entitlements'][key] = 'wrong'
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.cloud_entitlements(profile, self.config)
        for key, value in [('ExpirationDate', datetime(2000, 1, 1)),
                           ('TeamIdentifier', ['OTHERTEAM']), ('ProvisionsAllDevices', False)]:
            profile = self.profile(); profile[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.cloud_entitlements(profile, self.config)
        for key, value in [('get-task-allow', True), ('com.apple.security.get-task-allow', True),
                           ('com.apple.developer.aps-environment', 'development')]:
            profile = self.profile(); profile['Entitlements'][key] = value
            with self.assertRaises(ValueError): release.cloud_entitlements(profile, self.config)

    def test_release_requires_successful_storage_free_launch(self):
        import plistlib
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'Orbit.app'
            (bundle / 'Contents').mkdir(parents=True)
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Orbit'}))
            with patch.object(release, 'run', return_value=SimpleNamespace(
                    stdout='{"icloudAvailable":true,"storageInitialized":false}')) as run:
                release.verify_cloud_launch(bundle)
                run.assert_called_once_with(bundle / 'Contents/MacOS/Orbit', '--orbit-verify-icloud',
                                            capture_output=True, text=True, timeout=30)
            for output in ('{"icloudAvailable":false,"storageInitialized":false}',
                           '{"icloudAvailable":true,"storageInitialized":true}'):
                with patch.object(release, 'run', return_value=SimpleNamespace(stdout=output)):
                    with self.assertRaises(RuntimeError): release.verify_cloud_launch(bundle)
            for error in (subprocess.CalledProcessError(-9, 'Orbit'), subprocess.TimeoutExpired('Orbit', 30)):
                with patch.object(release, 'run', side_effect=error):
                    with self.assertRaises(type(error)): release.verify_cloud_launch(bundle)

    def test_cloud_entitlements_are_applied_only_to_the_main_app(self):
        from contextlib import nullcontext
        import plistlib
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'Orbit.app'
            helper = bundle / 'Contents/Frameworks/Orbit Helper.app/Contents/MacOS/Helper'
            helper.parent.mkdir(parents=True)
            helper.write_bytes(b'\xcf\xfa\xed\xfe')
            observed = []
            def run(arguments, **kwargs):
                if '--entitlements' in arguments:
                    filename = Path(arguments[arguments.index('--entitlements') + 1])
                    observed.append((Path(arguments[-1]), plistlib.loads(filename.read_bytes())))
                return b''
            expected = release.cloud_entitlements(self.profile(), self.config)
            with patch.object(local_signing, 'configured_identity', return_value=nullcontext(['--sign', 'synthetic'])), patch.object(local_signing, 'run', side_effect=run):
                local_signing.sign_chromium_bundle(bundle, 'Developer ID Application: Synthetic', expected)
            self.assertEqual(observed[-1][0], bundle)
            self.assertTrue(all(observed[-1][1][key] == value for key, value in expected.items()))
            self.assertTrue(all('com.apple.developer.icloud-services' not in values for path, values in observed[:-1]))
            self.assertTrue(all(values['com.apple.security.cs.allow-jit'] for _, values in observed))

    def test_no_profile_or_synthetic_bundle_never_embeds_cloud_capabilities(self):
        self.assertIsNone(release.embed_cloud_profile(Path('/unused'), self.config))
        self.assertIsNone(release.embed_cloud_profile(Path('/unused'), dict(self.config, provisioning_profile='/missing'), Path('/tmp/synthetic')))
        with self.assertRaises(ValueError):
            local_signing.sign_chromium_bundle(Path('/unused'), 'local', {'com.apple.developer.icloud-services': ['CloudKit']})


if __name__ == '__main__':
    unittest.main()
