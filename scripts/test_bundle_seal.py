"""Release guard regressions; live signed update coverage lives in test_update_ux.py."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import release
import test_update_ux as harness


class BundleSealTests(unittest.TestCase):
    def test_release_requires_every_post_launch_check(self):
        checks = dict.fromkeys(harness.BUNDLE_SEAL_CHECKS, True)
        release.check_bundle_seal_summary(checks)
        for name in checks:
            for bad in (False, None, 1):
                with self.subTest(name=name, bad=bad), self.assertRaises(RuntimeError):
                    release.check_bundle_seal_summary({**checks, name: bad})
            with self.assertRaises(RuntimeError):
                release.check_bundle_seal_summary({k: v for k, v in checks.items() if k != name})

    def test_fixture_adds_exact_generated_files_after_signing(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Orbit.app'
            with patch.object(harness.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)) as run:
                harness.break_host_seal(app)
            files = sorted(str(p.relative_to(app)) for p in app.rglob('*') if p.is_file())
            prefix = 'Contents/Resources/ContentBlocker/_metadata/generated_indexed_rulesets/'
            self.assertEqual(files, [prefix + '_ruleset1', prefix + '_ruleset2'])
            self.assertEqual(run.call_args.args[0], ['codesign', '--verify', '--deep', '--strict', str(app)])
            with patch.object(harness.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
                with self.assertRaises(RuntimeError):
                    harness.break_host_seal(app)

    def test_preservation_invokes_seal_case_before_accepting_candidate(self):
        source = Path(release.__file__).read_text()
        self.assertIn("'--cases', 'auth-transition', 'bundle-seal'", source)
        self.assertIn("check_bundle_seal_summary(json.loads((evidence / 'bundle-seal.json').read_text()))", source)


if __name__ == '__main__':
    unittest.main()
