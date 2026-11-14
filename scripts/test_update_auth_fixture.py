"""Offline checks of the auth-transition fixture and assertions in test_update_ux.py (no GUI)."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
SPEC = importlib.util.spec_from_file_location('update_ux', ROOT / 'scripts/test_update_ux.py')
update_ux = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update_ux)


class AuthFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.work = Path(self.temp.name)
        self.server = update_ux.auth_server(self.work)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = 'http://127.0.0.1:%d' % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def get(self, path, cookie=None):
        request = urllib.request.Request(self.base + path, headers={'Cookie': cookie} if cookie else {})
        with urllib.request.urlopen(request) as response:
            return response.read().decode(), response.headers.get_all('Set-Cookie') or []

    def test_login_sets_persistent_session_and_httponly_cookies(self):
        _, cookies = self.get('/login?profile=A&phase=login')
        by_name = {value.split('=', 1)[0]: value for value in cookies}
        self.assertEqual(set(by_name), {'auth', 'pref', 'sid'})
        self.assertIn('Max-Age=', by_name['auth'])
        self.assertIn('HttpOnly', by_name['auth'])
        self.assertIn('Max-Age=', by_name['pref'])
        self.assertNotIn('HttpOnly', by_name['pref'])
        self.assertNotIn('Max-Age=', by_name['sid'])
        self.assertIn('HttpOnly', by_name['sid'])
        _, second = self.get('/login2?profile=A&phase=login2')
        self.assertTrue(second[0].startswith('auth2=') and 'HttpOnly' in second[0] and 'Max-Age=' in second[0])

    def test_fixture_judges_tokens_and_profile_isolation(self):
        _, a = self.get('/login?profile=A&phase=p')
        _, b = self.get('/login?profile=B&phase=p')
        jar = lambda cookies: '; '.join(value.split(';', 1)[0] for value in cookies)
        body, _ = self.get('/whoami?profile=A&phase=p', jar(a))
        self.assertEqual(body, 'A auth=ok pref=ok sid=ok auth2=missing')
        body, _ = self.get('/whoami?profile=A&phase=p', jar(b))
        self.assertIn('auth=foreign', body)
        body, _ = self.get('/whoami?profile=B&phase=p', 'auth=stale-value')
        self.assertIn('auth=stale', body)
        lines = [json.loads(line) for line in (self.work / 'auth.log').read_text().splitlines()]
        self.assertTrue(all(set(entry['cookies'].values()) <= {'ok', 'foreign', 'stale', 'missing'} for entry in lines))
        self.assertNotIn(jar(a).split('=', 1)[1][:8], (self.work / 'auth.log').read_text())


def phase(a, b, page='js=pref'):
    return {'fixture': {'A': a, 'B': b}, 'page': {'A': 'A ' + page, 'B': 'B ' + page}, 'version': '1'}


OK = {'auth': 'ok', 'pref': 'ok', 'sid': 'ok', 'auth2': 'ok'}
RESTARTED = {'auth': 'ok', 'pref': 'ok', 'sid': 'missing', 'auth2': 'missing'}
LOST = {'auth': 'missing', 'pref': 'missing', 'sid': 'missing', 'auth2': 'missing'}


class AuthChecksTests(unittest.TestCase):
    def results(self, updated):
        restarted_new = dict(RESTARTED, auth2='ok')
        return {'checks': {}, 'stores': {}, 'phases': {
            'login': phase(OK, OK), 'old-restart': phase(RESTARTED, RESTARTED), 'updated': phase(updated, updated),
            'new-login': phase(OK, OK), 'new-restart': phase(restarted_new, restarted_new),
            'next-update': phase(restarted_new, restarted_new)}}

    def test_kept_passes_only_when_authentication_survives(self):
        self.assertTrue(all(update_ux.auth_checks(self.results(RESTARTED), 'kept').values()))
        failed = update_ux.auth_checks(self.results(LOST), 'kept')
        self.assertFalse(failed['update_keeps_persistent'])

    def test_lost_documents_the_regression(self):
        results = self.results(LOST)
        del results['phases']['new-login'], results['phases']['new-restart'], results['phases']['next-update']
        self.assertTrue(all(update_ux.auth_checks(results, 'lost').values()))

    def test_foreign_tokens_and_visible_httponly_cookies_fail(self):
        results = self.results(RESTARTED)
        results['phases']['updated']['fixture']['B'] = dict(RESTARTED, auth='foreign')
        self.assertFalse(update_ux.auth_checks(results, 'kept')['profiles_isolated'])
        results = self.results(RESTARTED)
        results['phases']['login']['page']['A'] = 'A js=auth,pref'
        self.assertFalse(update_ux.auth_checks(results, 'kept')['httponly_hidden_from_page'])


if __name__ == '__main__':
    unittest.main()
