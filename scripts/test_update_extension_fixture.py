"""Offline checks of the installed-extension preservation fixture (no GUI, no engine)."""
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import update_extension_fixture as fixture  # noqa: E402

SPEC = importlib.util.spec_from_file_location('update_ux', ROOT / 'scripts/test_update_ux.py')
update_ux = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update_ux)

SECOND = '11111111-2222-3333-4444-555555555555'
DEVICE = 'SYNTHETIC-DEVICE'


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.work = Path(self.temp.name) / 'work'
        self.work.mkdir()
        self.root = Path(self.temp.name) / 'data'
        self.description = fixture.build(self.work, 'http://127.0.0.1:9')

    def tearDown(self):
        self.temp.cleanup()

    def profiles(self):
        for name in ('profile-aaaaaaaa-0000-0000-0000-000000000000', 'profile-' + SECOND.lower()):
            profile = self.root / 'Chromium' / name
            profile.mkdir(parents=True)
            (profile / 'Secure Preferences').write_text(json.dumps({'protection': {'macs': {'extensions': {
                'settings': {}, 'settings_encrypted_hash': {'component': 'djEwAAAA'}}}, 'super_encrypted_hash': 'x'}}))
            (profile / 'Preferences').write_text('{}')

    def test_packages_are_signed_crx3_with_stable_ids_and_no_keys_left(self):
        crx = (self.work / 'ext/x-2.crx').read_bytes()
        self.assertEqual(crx[:4], b'Cr24')
        self.assertEqual(struct.unpack('<I', crx[4:8])[0], 3)
        self.assertEqual(list((self.work / 'ext').glob('*.pem')), [])
        x, y = (self.description['extensions'][label] for label in ('X', 'Y'))
        self.assertRegex(x['id'], '^[a-p]{32}$')
        self.assertNotEqual(x['id'], y['id'])
        self.assertEqual(x['manifest']['version'], '1.0')
        self.assertEqual(x['manifest']['update_url'], 'http://127.0.0.1:9/ext/update.xml')
        self.assertIn('action', x['manifest'])
        self.assertEqual(x['manifest']['host_permissions'], [fixture.HOST_PATTERN])

    def test_update_response_offers_only_x(self):
        body = fixture.update_response(self.description, 'http://127.0.0.1:9').decode()
        x, y = (self.description['extensions'][label]['id'] for label in ('X', 'Y'))
        self.assertIn('appid="%s"><updatecheck codebase="http://127.0.0.1:9/ext/x-2.crx" version="2.0"' % x, body)
        self.assertIn('appid="%s"><updatecheck status="noupdate"' % y, body)

    def test_reports_log_statuses_never_markers(self):
        record = lambda label, marker, phase='p': fixture.record_report(
            self.work, {'profile': label, 'ext': 'X', 'phase': phase, 'version': '2.0', 'marker': marker})
        self.assertTrue(record('A', 'marker-a'))
        self.assertTrue(record('B', 'marker-b'))
        self.assertTrue(record('A', 'marker-a', 'q'))
        self.assertTrue(record('A', 'marker-other', 'r'))
        self.assertTrue(record('B', 'marker-a', 's'))
        self.assertFalse(fixture.record_report(self.work, {'profile': 'C', 'ext': 'X'}))
        statuses = [entry['marker'] for entry in fixture.reports(self.work)]
        self.assertEqual(statuses, ['first', 'first', 'same', 'changed', 'foreign'])
        self.assertNotIn('marker-a', (self.work / 'ext.log').read_text())
        self.assertEqual((self.work / 'ext-markers.json').stat().st_mode & 0o777, 0o600)
        self.assertFalse(fixture.reported(self.work, 'p', '1.0'))
        self.assertTrue(fixture.reported(self.work, 'p'))

    def test_seed_writes_legacy_records_the_engine_can_authenticate(self):
        self.profiles()
        fixture.seed(self.root, self.work, SECOND, device=DEVICE)
        summary = fixture.store_summary(self.root, self.work, SECOND)
        self.assertEqual(set(summary), {'A', 'B'})
        for label in ('A', 'B'):
            x, y = summary[label]['X'], summary[label]['Y']
            self.assertTrue(x['present'] and x['enabled'] and x['pinned'] and x['legacy_mac'] and x['installed_dir'])
            self.assertTrue(x['granted_storage'] and x['granted_host'])
            self.assertIsNone(x['encrypted_hash'])
            self.assertEqual((x['version'], x['location']), ('1.0', fixture.INTERNAL))
            self.assertTrue(y['present'] and not y['enabled'] and not y['pinned'])
        profile = fixture.profile_directories(self.root, SECOND)['A']
        values = json.loads((profile / 'Secure Preferences').read_text())
        protection = values['protection']
        self.assertNotIn('super_encrypted_hash', protection)
        self.assertNotIn('settings_encrypted_hash', protection['macs']['extensions'])
        x_id = self.description['extensions']['X']['id']
        self.assertEqual(protection['macs']['extensions']['settings'][x_id],
                         fixture.legacy_mac(DEVICE, 'extensions.settings.' + x_id, values['extensions']['settings'][x_id]))
        self.assertEqual(protection['super_mac'], fixture.legacy_mac(DEVICE, '', protection['macs']))

    def test_mac_canonicalization_drops_empty_containers(self):
        self.assertEqual(fixture.legacy_mac(DEVICE, 'p', {'a': [], 'b': {}, 'c': 1}), fixture.legacy_mac(DEVICE, 'p', {'c': 1}))

    def test_profiles_must_be_exactly_the_two_synthetic_ones(self):
        with self.assertRaises(RuntimeError):
            fixture.profile_directories(self.root, SECOND)


def report(phase, label, ext='X', version='2.0', marker='same'):
    return {'phase': phase, 'profile': label, 'ext': ext, 'version': version, 'created': '1.0', 'marker': marker}


def kept_results():
    healthy = {'present': True, 'files': True, 'storage': True, 'pinned': True, 'legacy_mac': True,
               'encrypted_hash': 'v10', 'reset': False, 'version': '2.0', 'location': 1, 'enabled': True,
               'installed_dir': True, 'granted_storage': True, 'granted_host': True}
    disabled = dict(healthy, pinned=False, enabled=False, version='1.0', storage=False)
    store = {label: {'X': dict(healthy), 'Y': dict(disabled), 'reset_paths': [], 'reset_time': False,
                     'encrypted_kinds': ['v10']} for label in ('A', 'B')}
    listed = {label: [{'name': fixture.NAMES['X'], 'version': '2.0', 'enabled': True, 'pinned': True},
                      {'name': fixture.NAMES['Y'], 'version': '1.0', 'enabled': False, 'pinned': False}]
              for label in ('A', 'B')}
    reports = [report('ext-install', 'A', version='1.0', marker='first'), report('ext-installed', 'A', marker='same'),
               report('ext-installed', 'B', marker='first')]
    for phase in ('ext-restart', 'updated', 'new-restart', 'next-update'):
        reports += [report(phase, 'A'), report(phase, 'B')]
    backup = {'mode': '0o700', 'A': {'X': True, 'Y': True, 'cookies': True}, 'B': {'X': True, 'Y': True, 'cookies': True}}
    return {'extension_stores': {stage: json.loads(json.dumps(store)) for stage in update_ux.AUTH_STAGES[1:]},
            'inventory': {phase: listed for phase in ('updated', 'new-restart', 'next-update')},
            'ext_reports': reports, 'backups': {'auth-next': [backup]}}


class ChecksTests(unittest.TestCase):
    def test_kept_run_passes_every_check(self):
        checks = fixture.checks(kept_results(), 'kept')
        self.assertTrue(all(checks.values()), checks)
        self.assertIn('ext_next_update_inventory', checks)
        self.assertIn('migration_backup_restorable', checks)

    def test_each_regression_fails_its_check(self):
        cases = {
            'ext_updated_store_preserved': lambda r: r['extension_stores']['auth-update']['A']['X'].update(present=False),
            'ext_new_restart_inventory': lambda r: r['inventory']['new-restart']['B'].pop(0),
            'ext_next_update_reports_same_storage': lambda r: r['ext_reports'].append(report('next-update', 'A', marker='changed')),
            'ext_disabled_never_runs': lambda r: r['ext_reports'].append(report('updated', 'A', ext='Y')),
            'ext_markers_isolated': lambda r: r['ext_reports'].append(report('updated', 'B', marker='foreign')),
            'migration_backup_restorable': lambda r: r['backups'].update({'auth-next': []}),
            'ext_installed_by_previous_engine': lambda r: r['extension_stores']['ext-old']['B']['X'].update(encrypted_hash=None),
        }
        for name, damage in cases.items():
            results = kept_results()
            damage(results)
            self.assertFalse(fixture.checks(results, 'kept')[name], name)

    def test_unpinned_or_reset_records_fail(self):
        results = kept_results()
        results['extension_stores']['auth-restart']['A']['X']['pinned'] = False
        self.assertFalse(fixture.checks(results, 'kept')['ext_new_restart_store_preserved'])
        results = kept_results()
        results['extension_stores']['auth-next']['B']['Y']['reset'] = True
        self.assertFalse(fixture.checks(results, 'kept')['ext_next_update_store_preserved'])

    def test_lost_and_record_modes(self):
        results = kept_results()
        self.assertFalse(fixture.checks(results, 'lost')['ext_lost_after_update'])
        for label in ('A', 'B'):
            results['extension_stores']['auth-restart'][label]['X'] = {'present': False}
        self.assertTrue(fixture.checks(results, 'lost')['ext_lost_after_update'])
        self.assertNotIn('ext_updated_inventory', fixture.checks(results, 'record'))


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.work = Path(self.temp.name)
        self.server = update_ux.auth_server(self.work)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = 'http://127.0.0.1:%d' % self.server.server_port
        fixture.build(self.work, self.base)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def test_updater_and_reports_are_served_on_loopback_only(self):
        with urllib.request.urlopen(self.base + '/ext/update.xml?x=id%3Dabc') as response:
            self.assertIn(b'/ext/x-2.crx', response.read())
        with urllib.request.urlopen(self.base + '/ext/x-2.crx') as response:
            self.assertEqual(response.read()[:4], b'Cr24')
        with urllib.request.urlopen(self.base + '/ext-report?profile=A&phase=p&ext=X&version=2.0&marker=m%2D1') as response:
            self.assertEqual(response.read(), b'ok')
        self.assertEqual(fixture.reports(self.work), [report('p', 'A', marker='first') | {'created': ''}])
        proxied = urllib.request.Request(self.base + '/x')
        proxied.selector = 'http://example.com/x'
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(proxied)
        self.assertEqual(error.exception.code, 403)


if __name__ == '__main__':
    unittest.main()
