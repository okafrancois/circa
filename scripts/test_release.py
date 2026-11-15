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
import release_notes

NOTE_FIXTURE = Path(__file__).parent / 'fixtures/release-notes/1.2.3.md'


class ReleaseTests(unittest.TestCase):
    config = {'name': 'Circa', 'bundle_id': 'io.github.okatech.orbit',
              'repository': 'example/browser', 'public_ed_key': ''}

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

    def test_all_release_notes_are_valid(self):
        notes = release_notes.load_all(release.ROOT)
        self.assertTrue(any(note.version == '0.1.0' for note in notes))
        self.assertTrue(any(note.version == '0.71.2' for note in notes))

    def test_missing_or_invalid_notes_stop_before_building(self):
        with patch.object(release, 'run') as run, patch.object(release, 'release_notes_path', return_value=None):
            with self.assertRaises(ValueError):
                release.publish_release(self.config, '1.2.3', Path('app.zip'), Path('app.dmg'), Path('appcast.xml'))
            run.assert_not_called()
        with patch.object(sys, 'argv', ['release.py', '--tag', 'v0.71.2']), \
                patch.object(release, 'load_all', side_effect=ValueError('Invalid editorial note')), \
                patch.object(release, 'run') as run, patch.object(release, 'require_notary_profile') as notary:
            with self.assertRaisesRegex(ValueError, 'Invalid editorial note'):
                release.main()
            run.assert_not_called()
            notary.assert_not_called()

    def test_published_release_bodies_are_immutable(self):
        with patch.object(release, 'release_notes_path', return_value=NOTE_FIXTURE), \
                patch.object(release.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='{"isDraft":false}')), \
                patch.object(release, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'already published'):
                release.publish_release(self.config, '1.2.3', Path('app.zip'), Path('app.dmg'), Path('appcast.xml'))
            run.assert_not_called()

    def test_versions_are_semantic_and_builds_are_numeric(self):
        self.assertEqual(release.release_version('v0.1.0'), '0.1.0')
        self.assertEqual(release.release_version('v1.2.3-nightly.1'), '1.2.3-nightly.1')
        for tag in ['v1.2.3-nightly.0', 'v1.2.3-nightly', 'v1.2.3-nightly.1/other', '0.1.0', 'v1.2', 'v1.2.3-rc1', 'main']:
            with self.assertRaises(ValueError):
                release.release_version(tag)
        info = release.update_info({}, self.config, '0.1.0', 123)
        self.assertEqual(info['CFBundleVersion'], '123')
        self.assertEqual(info['CFBundleShortVersionString'], '0.1.0')
        self.assertEqual(info['SUScheduledCheckInterval'], 3600)
        self.assertTrue(info['SUAllowsAutomaticUpdates'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertIs(info['SURequireSignedFeed'], True)
        self.assertTrue(info['SUAutomaticallyUpdate'])
        self.assertEqual(info['SUFeedURL'], release.update_feed_url(self.config['repository']))

    def test_publish_commands_pin_latest_and_upload_stable_feed(self):
        responses = [SimpleNamespace(returncode=1), SimpleNamespace(returncode=1)]
        commands = []
        def fake_run(*args, **kwargs):
            commands.append(list(map(str, args)))
        with patch.object(release, 'release_notes_path', return_value=NOTE_FIXTURE), \
                patch.object(release.subprocess, 'run', side_effect=responses), patch.object(release, 'run', side_effect=fake_run):
            release.publish_release(self.config, '1.2.3', Path('app.zip'), Path('app.dmg'), Path('appcast.xml'))
        publish_edit = next(command for command in commands if command[:3] == ['gh', 'release', 'edit'])
        feed_create = next(command for command in commands if command[:4] == ['gh', 'release', 'create', 'update-feed'])
        feed_upload = next(command for command in commands if command[:4] == ['gh', 'release', 'upload', 'update-feed'])
        self.assertEqual(publish_edit, ['gh', 'release', 'edit', 'v1.2.3', '--repo', self.config['repository'], '--draft=false', '--latest'])
        self.assertEqual(commands[1], ['gh', 'release', 'upload', 'v1.2.3', '--repo', self.config['repository'], '--clobber', 'app.zip', 'app.dmg', 'appcast.xml'])
        self.assertIn('--prerelease', feed_create)
        self.assertIn('--latest=false', feed_create)
        self.assertEqual(feed_upload, ['gh', 'release', 'upload', 'update-feed', '--repo', self.config['repository'], '--clobber', 'appcast.xml'])

    def test_publish_uses_editorial_notes_when_present(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            notes = root / 'release/notes/1.2.3.md'
            notes.parent.mkdir(parents=True)
            notes.write_text(NOTE_FIXTURE.read_text())
            commands = []
            bodies = []
            def record(*args, **kwargs):
                commands.append(list(map(str, args)))
                if '--notes-file' in args:
                    bodies.append(Path(args[args.index('--notes-file') + 1]).read_text())
            responses = [SimpleNamespace(returncode=1), SimpleNamespace(returncode=1)]
            with patch.object(release, 'ROOT', root), patch.object(release.subprocess, 'run', side_effect=responses), \
                    patch.object(release, 'run', side_effect=record):
                release.publish_release(self.config, '1.2.3', Path('app.zip'), Path('app.dmg'), Path('appcast.xml'))
                self.assertEqual(release.release_notes_path('1.2.3'), notes)
                with self.assertRaises(ValueError):
                    release.release_notes_path('1.2.3/../../other')
            create = next(command for command in commands if command[:3] == ['gh', 'release', 'create'])
            self.assertEqual(create[-2], '--notes-file')
            self.assertNotEqual(create[-1], str(notes))
            self.assertEqual(bodies, [release_notes.github_body(release_notes.load(notes))])
            self.assertNotIn('date:', bodies[0])
            self.assertIn('1 new · 1 faster · 1 fixed', bodies[0])
            self.assertNotIn('--generate-notes', create)

    def test_publish_uploads_unversioned_stable_dmg(self):
        responses = [SimpleNamespace(returncode=1), SimpleNamespace(returncode=1)]
        commands = []
        with patch.object(release, 'release_notes_path', return_value=NOTE_FIXTURE), \
                patch.object(release.subprocess, 'run', side_effect=responses), \
                patch.object(release, 'run', side_effect=lambda *args, **kwargs: commands.append(list(map(str, args)))):
            release.publish_release(self.config, '1.2.3', Path('app.zip'), Path('app.dmg'), Path('appcast.xml'),
                                    stable_dmg=Path('Circa.dmg'))
        self.assertEqual(commands[1], ['gh', 'release', 'upload', 'v1.2.3', '--repo', self.config['repository'], '--clobber',
                                       'app.zip', 'app.dmg', 'Circa.dmg', 'appcast.xml'])

    def test_nightly_notes_and_publishing_never_change_latest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            notes = root / 'release/notes/nightly/1.2.3-nightly.1.md'
            with patch.object(release, 'ROOT', root):
                with self.assertRaises(ValueError):
                    release.release_notes_path('1.2.3-nightly.1')
                notes.parent.mkdir(parents=True)
                notes.write_text('---\ndate: 2026-11-15\ntitle: Try new features first.\n---\n\n## New\n\n- Try new features in Advanced Settings.\n')
                dmg = root / 'versioned.dmg'
                dmg.write_bytes(b'test')
                commands = []
                with patch.object(release.subprocess, 'run', return_value=SimpleNamespace(returncode=1)), \
                        patch.object(release, 'run', side_effect=lambda *args, **kw: commands.append(list(map(str, args)))):
                    release.publish_release(self.config, '1.2.3-nightly.1', Path('app.zip'), dmg, Path('appcast.xml'),
                                            stable_dmg=Path('Circa.dmg'))
                self.assertTrue((root / 'Circa-Nightly.dmg').is_file())
                for command in commands:
                    self.assertNotIn('--latest', command)
                    self.assertNotIn('Circa.dmg', command)
                    if command[2] in ('create', 'edit'):
                        self.assertIn('--prerelease', command)
                        self.assertIn('--latest=false', command)
                self.assertTrue(any(command[2:4] == ['upload', 'nightly'] for command in commands))

    def test_channel_predecessors_and_feed_retention(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def item(build, channel=''):
                return ('<item><sparkle:version>%s</sparkle:version>%s'
                        '<enclosure url="https://example.test/%s.zip" sparkle:edSignature="sig"/>'
                        '<sparkle:deltas><enclosure url="https://example.test/%s.delta"/></sparkle:deltas></item>' %
                        (build, '<sparkle:channel>%s</sparkle:channel>' % channel if channel else '', build, build))
            def feed(path, items):
                path.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' + items + '</channel></rss>')
            previous, current = root / 'previous.xml', root / 'appcast.xml'
            feed(previous, item(1) + item(2, 'nightly') + item(3, 'nightly'))
            self.assertEqual([i[0] for i in release.preservation_items(previous, True)], [3])
            self.assertEqual([i[0] for i in release.preservation_items(previous, False)], [1, 3])
            feed(current, item(4, 'nightly'))
            release.merge_published_items(current, previous, 4, True)
            self.assertEqual(release.latest_feed_item(current, '')[0], 1)
            self.assertEqual(release.latest_feed_item(current, 'nightly')[0], 4)
            self.assertIn('https://example.test/2.delta', current.read_text())
            with self.assertRaises(ValueError):
                release.merge_published_items(current, previous, 4, False)
            feed(current, item(5))
            release.merge_published_items(current, previous, 5, False)
            self.assertEqual([i[0] for i in release.preservation_items(current, False)], [5, 3])

    def test_release_enables_quarantine_even_for_older_source_bundles(self):
        for source in ({}, {'LSFileQuarantineEnabled': False}):
            with self.subTest(source=source):
                info = release.update_info(source, self.config, '0.1.0', 123)
                self.assertIs(info.get('LSFileQuarantineEnabled'), True)
        config = dict(self.config, bundle_id='io.github.okatech.orbit.test.update')
        info = release.update_info({}, config, '0.1.0', 123, Path('/tmp/test'),
                                   'http://127.0.0.1:12345/appcast.xml')
        self.assertIs(info.get('LSFileQuarantineEnabled'), True)

    @staticmethod
    def signed(content):
        # Same trailer layout as sign_update and generate_appcast; the signature bytes are synthetic.
        data = content.encode()
        signature = __import__('base64').b64encode(bytes(range(64))).decode()
        return data + ('<!-- sparkle-signatures:\nedSignature: %s\nlength: %d\n-->\n' % (signature, len(data))).encode()

    def test_feed_requires_the_newest_release_and_a_full_signed_archive(self):
        content = ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
                   '<item><sparkle:version>27</sparkle:version><enclosure url="https://example.test/latest.zip" '
                   'sparkle:edSignature="test"/><sparkle:deltas><enclosure sparkle:version="999"/></sparkle:deltas></item>'
                   '<item><sparkle:version>25</sparkle:version></item></channel></rss>')
        with tempfile.TemporaryDirectory() as temporary:
            feed = Path(temporary) / 'appcast.xml'
            feed.write_bytes(self.signed(content))
            release.validate_appcast(feed, 27)
            with self.assertRaises(ValueError):
                release.validate_appcast(feed, 25)
            feed.write_bytes(self.signed(content.replace('sparkle:edSignature="test"', '')))
            with self.assertRaises(ValueError):
                release.validate_appcast(feed, 27)

    def test_feed_signature_is_required_and_covers_the_whole_feed(self):
        content = ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
                   '<item><sparkle:version>27</sparkle:version><enclosure url="https://example.test/latest.zip" '
                   'sparkle:edSignature="test"/></item></channel></rss>')
        signed, signature = release.feed_signature(self.signed(content))
        self.assertEqual(signed, content.encode())
        self.assertEqual(len(__import__('base64').b64decode(signature)), 64)
        with tempfile.TemporaryDirectory() as temporary:
            feed = Path(temporary) / 'appcast.xml'
            feed.write_text(content)
            with self.assertRaisesRegex(ValueError, 'feed signature'):
                release.validate_appcast(feed, 27)
        tampered = self.signed(content).replace(b'<sparkle:version>27', b'<sparkle:version>28')
        release.feed_signature(tampered)  # Same length: only the cryptographic check can reject it.
        for data in [self.signed(content).replace(b'</rss>', b'</rss>\n'), self.signed(content) + b'<extra/>',
                     content.encode() + self.signed('<rss/>')[len(b'<rss/>'):]]:
            with self.assertRaises(ValueError):
                release.feed_signature(data)

    def test_every_product_plist_requires_a_signed_feed(self):
        spec = importlib.util.spec_from_file_location('orbit_app_info', Path(__file__).parent / 'orbit-app.py')
        packaging = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(packaging)
        self.assertIs(packaging.bundle_info('0.1.0')['SURequireSignedFeed'], True)
        template = (Path(__file__).parents[1] / 'native/OrbitChromium/App/Info.plist.in').read_text()
        self.assertIn('<key>SURequireSignedFeed</key><true/>', template)

    def test_synthetic_roots_do_not_leak_into_product(self):
        info = release.update_info({'OrbitDataRoot': '/tmp/test', 'OrbitSyntheticBundle': True,
                                    'OrbitUseMockKeychain': True, 'OrbitUpdaterLocalTest': True},
                                   self.config, '0.1.0', 123)
        self.assertFalse(any(key in info for key in ['OrbitDataRoot', 'OrbitSyntheticBundle', 'OrbitUseMockKeychain', 'OrbitUpdaterLocalTest']))
        self.assertEqual(info['CFBundleName'], 'Circa')
        self.assertEqual(info['CFBundleDisplayName'], 'Circa')
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
            self.assertFalse(any(key.startswith('com.apple.security.cs.') for key in observed[-1][1]))
            for capability in ('com.apple.security.device.audio-input', 'com.apple.security.device.camera',
                               'com.apple.security.personal-information.location'):
                self.assertIs(observed[-1][1][capability], True)
                self.assertTrue(all(capability not in values for _, values in observed[:-1]))

    def test_local_synthetic_signing_keeps_media_capabilities_without_cloud_grants(self):
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
            with patch.object(local_signing, 'configured_identity', return_value=nullcontext(['--sign', 'synthetic'])), patch.object(local_signing, 'run', side_effect=run):
                local_signing.sign_chromium_bundle(bundle)
            self.assertEqual(observed[-1][0], bundle)
            self.assertIs(observed[-1][1]['com.apple.security.device.audio-input'], True)
            self.assertIs(observed[-1][1]['com.apple.security.device.camera'], True)
            self.assertIs(observed[-1][1]['com.apple.security.personal-information.location'], True)
            self.assertTrue(all('com.apple.developer.icloud-services' not in values for _, values in observed))
            self.assertTrue(all('com.apple.security.device.camera' not in values and
                                'com.apple.security.device.audio-input' not in values for _, values in observed[:-1]))

    def test_no_profile_or_synthetic_bundle_never_embeds_cloud_capabilities(self):
        self.assertIsNone(release.embed_cloud_profile(Path('/unused'), self.config))
        self.assertIsNone(release.embed_cloud_profile(Path('/unused'), dict(self.config, provisioning_profile='/missing'), Path('/tmp/synthetic')))
        with self.assertRaises(ValueError):
            local_signing.sign_chromium_bundle(Path('/unused'), 'local', {'com.apple.developer.icloud-services': ['CloudKit']})


class ScopedEntitlementTests(unittest.TestCase):
    """Developer ID signatures scope runtime exceptions per process; local ones stay broad."""
    JIT = 'com.apple.security.cs.allow-jit'
    UNSIGNED = 'com.apple.security.cs.allow-unsigned-executable-memory'
    NO_LIBRARY_VALIDATION = 'com.apple.security.cs.disable-library-validation'
    HELPERS = ('', ' (Renderer)', ' (GPU)', ' (Plugin)', ' (Alerts)')

    def synthetic_bundle(self, root):
        import plistlib
        bundle = Path(root) / 'Orbit.app'
        for suffix in self.HELPERS:
            name = 'Orbit Helper' + suffix
            executable = bundle / 'Contents/Frameworks' / (name + '.app') / 'Contents/MacOS' / name
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'\xcf\xfa\xed\xfe')
        downloader = bundle / 'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader'
        downloader.parent.mkdir(parents=True)
        downloader.write_bytes(b'\xcf\xfa\xed\xfe')
        framework = bundle / 'Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework'
        framework.parent.mkdir(parents=True)
        framework.write_bytes(b'\xcf\xfa\xed\xfe')
        return bundle

    def sign(self, bundle, identity, main_entitlements=None):
        from contextlib import nullcontext
        import plistlib
        observed, preserved = {}, []
        def run(arguments, **kwargs):
            target = Path(arguments[-1])
            if '--entitlements' in arguments:
                filename = Path(arguments[arguments.index('--entitlements') + 1])
                observed[target] = plistlib.loads(filename.read_bytes())
            elif '--preserve-metadata=entitlements' in arguments:
                preserved.append(target)
            elif arguments[1] == '--force':
                observed[target] = {}
            return b''
        with patch.object(local_signing, 'configured_identity', return_value=nullcontext(['--sign', 'synthetic'])), \
                patch.object(local_signing, 'run', side_effect=run):
            local_signing.sign_chromium_bundle(bundle, identity, main_entitlements)
        return observed, preserved

    def code_signing(self, values):
        return {key for key in values if key.startswith('com.apple.security.cs.')}

    def test_developer_id_scopes_each_helper_and_keeps_the_host_validated(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.synthetic_bundle(temporary)
            observed, preserved = self.sign(bundle, 'Developer ID Application: Synthetic (TEAM123456)')
            self.assertEqual(self.code_signing(observed[bundle]), set())
            for capability in ('com.apple.security.device.audio-input', 'com.apple.security.device.camera',
                               'com.apple.security.personal-information.location'):
                self.assertIs(observed[bundle][capability], True)
            expected = {'': {self.NO_LIBRARY_VALIDATION}, ' (Renderer)': {self.JIT}, ' (GPU)': {self.JIT},
                        ' (Plugin)': {self.UNSIGNED, self.NO_LIBRARY_VALIDATION}, ' (Alerts)': set()}
            for suffix, values in expected.items():
                name = 'Orbit Helper' + suffix
                helper = bundle / 'Contents/Frameworks' / (name + '.app')
                for target in (helper, helper / 'Contents/MacOS' / name):
                    self.assertEqual(set(observed[target]), values, target)
            framework = bundle / 'Contents/Frameworks/Chromium Embedded Framework.framework'
            self.assertEqual(observed[framework], {})
            self.assertEqual(observed[framework / 'Chromium Embedded Framework'], {})
            self.assertTrue(all('Downloader' in str(path) for path in preserved) and len(preserved) == 2)

    def test_local_identity_keeps_the_broad_set_everywhere(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.synthetic_bundle(temporary)
            observed, _ = self.sign(bundle, 'local')
            broad = {self.JIT, self.UNSIGNED, self.NO_LIBRARY_VALIDATION}
            self.assertEqual(self.code_signing(observed[bundle]), broad)
            for suffix in self.HELPERS:
                helper = bundle / 'Contents/Frameworks' / ('Orbit Helper' + suffix + '.app')
                self.assertEqual(set(observed[helper]), broad)

    def test_unclassified_helpers_and_host_exceptions_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.synthetic_bundle(temporary)
            unknown = bundle / 'Contents/Frameworks/Orbit Helper (EH).app/Contents/MacOS/Orbit Helper (EH)'
            unknown.parent.mkdir(parents=True)
            unknown.write_bytes(b'\xcf\xfa\xed\xfe')
            with self.assertRaises(ValueError):
                self.sign(bundle, 'Developer ID Application: Synthetic (TEAM123456)')
            self.sign(bundle, 'local')
        with self.assertRaises(ValueError):
            local_signing.host_entitlements('Developer ID Application: Synthetic', {self.NO_LIBRARY_VALIDATION: True})

    def signed_table(self, bundle, **overrides):
        values = {bundle: {'com.apple.security.device.camera': True}}
        allowed = local_signing.DEVELOPER_ID_HELPER_ENTITLEMENTS
        for suffix in self.HELPERS:
            values[bundle / 'Contents/Frameworks' / ('Orbit Helper' + suffix + '.app')] = dict.fromkeys(allowed[suffix], True)
        for name, entitlements in overrides.items():
            values[bundle if name == 'host' else bundle / 'Contents/Frameworks' / name] = entitlements
        return values

    def test_release_assertion_accepts_only_the_scoped_table(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.synthetic_bundle(temporary)
            release.verify_scoped_entitlements(bundle, read=self.signed_table(bundle).__getitem__)
            failures = [
                {'host': {self.NO_LIBRARY_VALIDATION: True}},
                {'host': {self.JIT: True, 'com.apple.security.device.camera': True}},
                {'Orbit Helper.app': {self.NO_LIBRARY_VALIDATION: True, self.JIT: True}},
                {'Orbit Helper (Renderer).app': {self.JIT: True, self.UNSIGNED: True}},
                {'Orbit Helper (GPU).app': {self.JIT: True, self.NO_LIBRARY_VALIDATION: True}},
                {'Orbit Helper (Alerts).app': {self.JIT: True}},
            ]
            for overrides in failures:
                with self.subTest(overrides=overrides), self.assertRaises(RuntimeError):
                    release.verify_scoped_entitlements(bundle, read=self.signed_table(bundle, **overrides).__getitem__)
            import shutil
            shutil.rmtree(bundle / 'Contents/Frameworks/Orbit Helper (Alerts).app')
            with self.assertRaises(RuntimeError):
                release.verify_scoped_entitlements(bundle, read=self.signed_table(bundle).__getitem__)


class PreservationGateTests(unittest.TestCase):
    """The update preservation gate cannot be passed by a partial, foreign or mismatched run."""
    config = {'name': 'Circa', 'bundle_id': 'io.github.okatech.orbit', 'repository': 'example/browser',
              'public_ed_key': 'A' * 43 + '=', 'team_id': 'TEAM123456'}
    identity = {'previous': {'build': '820', 'executable': 'a', 'framework': 'b'},
                'candidate': {'build': '830', 'executable': 'c', 'framework': 'd'}}

    def summary(self, **changes):
        value = {'case': 'auth-transition', 'run_id': 'run', 'expect': 'kept', 'extensions_expect': 'kept',
                 'inputs': dict(self.identity), 'passed': True,
                 'checks': {name: True for name in release.REQUIRED_PRESERVATION_CHECKS}}
        value.update(changes)
        return value

    def check(self, summary):
        release.check_preservation_summary(summary, 'run', self.identity['previous'], self.identity['candidate'])

    def test_complete_passing_run_is_accepted(self):
        self.check(self.summary())

    def test_every_gap_is_refused(self):
        partial = self.summary()
        del partial['checks']['ext_next_update_inventory']
        failing = self.summary()
        failing['checks']['ext_updated_store_preserved'] = False
        truthy = self.summary()
        truthy['checks']['update_keeps_persistent'] = 'yes'
        swapped = self.summary(inputs={'previous': self.identity['candidate'], 'candidate': self.identity['candidate']})
        for summary in (partial, failing, truthy, swapped, self.summary(run_id='other'), self.summary(passed=False),
                        self.summary(extensions_expect='record'), self.summary(expect='lost'), self.summary(case='x')):
            with self.assertRaises(RuntimeError):
                self.check(summary)

    def test_required_checks_cover_sign_ins_extensions_and_backup(self):
        names = set(release.REQUIRED_PRESERVATION_CHECKS)
        for name in ('next_update_keeps_old_and_new', 'ext_installed_by_previous_engine', 'ext_next_update_inventory',
                     'ext_next_update_store_preserved', 'ext_disabled_never_runs', 'migration_backup_verified'):
            self.assertIn(name, names)

    def feed(self, directory, *items):
        entries = ''.join(
            '<item><sparkle:version>%d</sparkle:version><sparkle:shortVersionString>%s</sparkle:shortVersionString>'
            '<enclosure url="%s" length="4" sparkle:edSignature="sig%d"/></item>' % (build, short, url, build)
            for build, short, url in items)
        path = directory / 'appcast.xml'
        path.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
                        + entries + '</channel></rss>')
        return path

    def test_latest_feed_item_is_the_newest_signed_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = self.feed(Path(temporary), (811, '0.68.5', 'https://x/a.zip'), (820, '0.69.1', 'https://x/b.zip'))
            self.assertEqual(release.latest_feed_item(path), (820, '0.69.1', 'https://x/b.zip', 4, 'sig820'))
            Path(temporary, 'empty.xml').write_text('<rss><channel/></rss>')
            with self.assertRaises(ValueError):
                release.latest_feed_item(Path(temporary, 'empty.xml'))

    def test_previous_release_refuses_unverified_or_foreign_inputs(self):
        prefix = 'https://github.com/example/browser/releases/download/v0.69.1/'
        cases = [((820, '0.69.1', 'https://elsewhere.example/Circa-0.69.1.zip'), 830, 'outside'),
                 ((830, '0.69.2', prefix + 'Circa-0.69.2.zip'), 830, 'newer'),
                 ((820, '0.69.1', prefix + 'Circa-0.69.1.zip'), 830, 'length')]
        for item, candidate, reason in cases:
            with tempfile.TemporaryDirectory() as temporary:
                work = Path(temporary)
                def fetch(url, destination):
                    if url.endswith('appcast.xml'):
                        self.feed(work, item)
                        if destination != work / 'appcast.xml':
                            Path(destination).write_bytes((work / 'appcast.xml').read_bytes())
                    else:
                        Path(destination).write_bytes(b'too long for the feed')
                with patch.object(release, 'verify_feed_signature') as verify, patch.object(release, 'run') as runner:
                    with self.assertRaises(ValueError, msg=reason):
                        release.previous_release(self.config, work, candidate, fetch=fetch)
                    verify.assert_called_once()
                    self.assertFalse(any('ditto' in map(str, call.args) for call in runner.call_args_list), reason)

    def test_gate_qualifies_every_required_channel_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            item = (10, '1.0.0', 'https://x/app.zip', 4, 'sig')
            nightly = (11, '1.1.0-nightly.1', 'https://x/nightly.zip', 4, 'sig')
            with patch.object(release, 'download'), patch.object(release, 'verify_feed_signature'), \
                    patch.object(release, 'latest_feed_item', return_value=nightly), \
                    patch.object(release, 'preservation_items', return_value=[item, nightly]), \
                    patch.object(release, 'qualify_previous') as qualify:
                release.qualify_preservation(self.config, Path('candidate.app'), 12, output)
                self.assertEqual([call.args[-1] for call in qualify.call_args_list], [item, nightly])
                qualify.reset_mock()
                with self.assertRaises(ValueError):
                    release.qualify_preservation(self.config, Path('candidate.app'), 11, output)
                qualify.assert_not_called()
                qualify.side_effect = RuntimeError('failed preservation')
                with self.assertRaises(RuntimeError):
                    release.qualify_preservation(self.config, Path('candidate.app'), 12, output)

    def test_gate_runs_before_signing_for_every_non_isolated_release(self):
        source = Path(release.__file__).read_text()
        gate = source.index('qualify_preservation(config, source, build, output, nightly=nightly)')
        self.assertLess(gate, source.index('prepare_bundle(source, app, config'))
        self.assertLess(gate, source.index("publish_release(config, version, archive, dmg, archives"))
        self.assertIn('if args.publish or args.qualify_only or not args.local_test_root:', source)
        self.assertNotIn('skip-preservation', source)


class PasskeyProfileTests(unittest.TestCase):
    config = CloudProfileTests.config
    profile = CloudProfileTests.profile

    def test_current_profile_requests_no_passkey_capability(self):
        profile = self.profile()
        profile['Entitlements']['keychain-access-groups'] = ['5Y39TTNCM7.*']
        self.assertEqual(release.passkey_entitlements(profile, self.config), {})
        for value in (False, 'true', 1, ['*']):
            profile['Entitlements'][release.BROWSER_PASSKEY_ENTITLEMENT] = value
            with self.subTest(value=value):
                self.assertEqual(release.passkey_entitlements(profile, self.config), {})

    def test_granted_browser_entitlement_is_requested(self):
        profile = self.profile()
        profile['Entitlements'][release.BROWSER_PASSKEY_ENTITLEMENT] = True
        self.assertEqual(release.passkey_entitlements(profile, self.config),
                         {release.BROWSER_PASSKEY_ENTITLEMENT: True})

    def test_keychain_group_requires_configuration_and_profile_admission(self):
        group = '5Y39TTNCM7.io.github.okatech.orbit.webauthn'
        config = dict(self.config, webauthn_keychain_access_group=group)
        for allowed in (['5Y39TTNCM7.*'], [group], ['OTHER.*', '5Y39TTNCM7.io.github.okatech.*']):
            profile = self.profile(); profile['Entitlements']['keychain-access-groups'] = allowed
            with self.subTest(allowed=allowed):
                self.assertEqual(release.passkey_entitlements(profile, config), {'keychain-access-groups': [group]})
        for configured, allowed in [(group, None), (group, ['OTHER.*']), (group, ['5Y39TTNCM7.com.*']),
                                    ('.org.chromium.Chromium.webauthn', ['5Y39TTNCM7.*']),
                                    ('OTHER.io.github.okatech.orbit.webauthn', ['*']),
                                    ('5Y39TTNCM7.*', ['5Y39TTNCM7.*'])]:
            profile = self.profile()
            if allowed is not None:
                profile['Entitlements']['keychain-access-groups'] = allowed
            with self.subTest(configured=configured, allowed=allowed), self.assertRaises(ValueError):
                release.passkey_entitlements(profile, dict(self.config, webauthn_keychain_access_group=configured))

    def test_keychain_group_must_be_compiled_into_the_engine(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'Orbit.app'
            engine = bundle / release.ENGINE_BINARY
            engine.parent.mkdir(parents=True)
            engine.write_bytes(b'\0.org.chromium.Chromium.webauthn\0.org.chromium.Chromium.webauthn-uvk\0')
            release.require_engine_keychain_group(bundle, '.org.chromium.Chromium.webauthn')
            for group in ('5Y39TTNCM7.io.github.okatech.orbit.webauthn', '.org.chromium.Chromium.webauth'):
                with self.subTest(group=group), self.assertRaises(ValueError):
                    release.require_engine_keychain_group(bundle, group)

    def test_embedded_profile_adds_granted_passkeys_to_the_main_app_request(self):
        import plistlib
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'Orbit.app'
            (bundle / 'Contents').mkdir(parents=True)
            source = Path(temporary) / 'profile.provisionprofile'
            source.write_bytes(b'signed-profile')
            for granted in (False, True):
                profile = self.profile()
                profile['DeveloperCertificates'] = [b'certificate']
                if granted:
                    profile['Entitlements'][release.BROWSER_PASSKEY_ENTITLEMENT] = True
                with self.subTest(granted=granted), patch.object(
                        release, 'run', return_value=SimpleNamespace(stdout=plistlib.dumps(profile))):
                    entitlements = release.embed_cloud_profile(bundle, dict(self.config, provisioning_profile=str(source)))
                    self.assertEqual(release.BROWSER_PASSKEY_ENTITLEMENT in entitlements, granted)
                    self.assertEqual(entitlements['com.apple.developer.icloud-services'], ['CloudKit'])
                    self.assertEqual((bundle / 'Contents/embedded.provisionprofile').read_bytes(), b'signed-profile')

    def test_release_requires_the_executed_signature_to_admit_passkeys(self):
        import plistlib
        import subprocess
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'Orbit.app'
            (bundle / 'Contents').mkdir(parents=True)
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Orbit'}))
            for state in ('authorized', 'denied', 'notDetermined'):
                output = json.dumps({'browserPasskeys': True, 'authorization': state})
                with patch.object(release, 'run', return_value=SimpleNamespace(stdout=output)) as run:
                    release.verify_passkey_launch(bundle)
                    run.assert_called_once_with(bundle / 'Contents/MacOS/Orbit', '--orbit-verify-passkeys',
                                                capture_output=True, text=True, timeout=30)
            for output in ('{"browserPasskeys":false,"authorization":"unavailable"}',
                           '{"browserPasskeys":true,"authorization":"unknown"}', '{}'):
                with patch.object(release, 'run', return_value=SimpleNamespace(stdout=output)):
                    with self.assertRaises(RuntimeError): release.verify_passkey_launch(bundle)
            for error in (subprocess.CalledProcessError(-9, 'Orbit'), subprocess.TimeoutExpired('Orbit', 30)):
                with patch.object(release, 'run', side_effect=error):
                    with self.assertRaises(type(error)): release.verify_passkey_launch(bundle)


if __name__ == '__main__':
    unittest.main()
