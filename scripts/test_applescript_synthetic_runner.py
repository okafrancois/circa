#!/usr/bin/env python3
"""Non-GUI checks for the self-targeted scripting probe's consent stop condition."""
import unittest
import test_applescript_synthetic as runner


class ConsentMonitorTests(unittest.TestCase):
    def test_identity_lookup_is_not_a_consent_request(self):
        self.assertFalse(runner.consent_requested(
            'Prompting policy for hardened runtime; service: kTCCServiceAppleEvents '
            'requires entitlement com.apple.security.automation.apple-events but it is missing'))

    def test_actual_prompt_stops_the_run(self):
        self.assertTrue(runner.consent_requested('AUTHREQ_PROMPTING: msgID=123.1'))
        self.assertTrue(runner.consent_requested('Will prompt for consent'))

    def test_non_preflight_automation_request_stops_before_prompt(self):
        self.assertTrue(runner.consent_requested(
            'AUTHREQ_CTX: msgID=123.1, service=kTCCServiceAppleEvents, preflight=no, query=1'))
        self.assertFalse(runner.consent_requested(
            'AUTHREQ_CTX: msgID=123.1, service=kTCCServiceAppleEvents, preflight=yes, query=1'))
        self.assertFalse(runner.consent_requested(
            'AUTHREQ_CTX: msgID=123.1, service=kTCCServiceListenEvent, preflight=yes, query=1'))


if __name__ == '__main__':
    unittest.main()
