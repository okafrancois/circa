"""Ephemeral signing admission and redaction, without accessing any real keychain."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ci_signing


class SigningSetupTests(unittest.TestCase):
    def test_missing_secrets_fail_before_creating_credentials_or_keychain(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True):
            directory = Path(temporary) / 'credentials'
            with patch.object(ci_signing, 'security') as security:
                with self.assertRaisesRegex(RuntimeError, 'Missing repository secrets'):
                    ci_signing.prepare(directory)
                security.assert_not_called()
            self.assertFalse(directory.exists())

    def test_credentials_stay_private_and_notary_password_never_enters_argv(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = {name: base64.b64encode(b'synthetic fixture').decode() for name in ci_signing.REQUIRED}
            env['CIRCA_SIGNING_PASSWORD'] = 'synthetic-package-password'
            env['CIRCA_SPARKLE_PRIVATE_KEY'] = 'synthetic-update-key'
            env['CIRCA_NOTARY_CREDENTIALS'] = json.dumps(dict(apple_id='fixture@example.test', password='synthetic-notary-password', team_id='SYNTHETIC'))
            env['GITHUB_ENV'] = str(root / 'environment')
            with patch.dict(os.environ, env), patch.object(ci_signing, 'security'), patch.object(ci_signing, 'identity'), patch.object(ci_signing, 'search_list', return_value=['/synthetic/original.keychain']), patch.object(ci_signing, 'checked') as checked:
                directory = root / 'credentials'
                ci_signing.prepare(directory)
            self.assertFalse((directory / 'identity.p12').exists())
            self.assertEqual((directory / 'sparkle-key').stat().st_mode & 0o777, 0o600)
            self.assertNotIn('synthetic-notary-password', ' '.join(checked.call_args.args[0]))
            self.assertEqual(checked.call_args.kwargs['data'], b'synthetic-notary-password\n')
            published = (root / 'environment').read_text()
            self.assertNotIn('synthetic-notary-password', published)
            self.assertNotIn('synthetic-update-key', published)
            self.assertEqual(json.loads((directory / 'config.json').read_text())['provisioning_profile'], str(directory / 'profile.provisionprofile'))

    def test_command_failure_does_not_repeat_sensitive_stderr(self):
        failure = subprocess.CompletedProcess(['synthetic-command'], 1, b'', b'synthetic secret in stderr')
        with patch.object(ci_signing.subprocess, 'run', return_value=failure):
            with self.assertRaises(RuntimeError) as error:
                ci_signing.checked(['synthetic-command'])
        self.assertNotIn('synthetic secret', str(error.exception))

    def test_local_or_self_hosted_use_is_refused(self):
        for environment in ({}, {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted'}):
            with self.subTest(environment=environment), patch.dict(os.environ, environment, clear=True), patch('sys.argv', ['ci_signing.py']):
                with self.assertRaisesRegex(RuntimeError, 'ephemeral GitHub-hosted'):
                    ci_signing.main()


if __name__ == '__main__':
    unittest.main()
