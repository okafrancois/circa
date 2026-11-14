#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "content-blocking-rules.py"
spec = importlib.util.spec_from_file_location("content_blocking_rules", SCRIPT)
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)


class ConversionTests(unittest.TestCase):
    def convert(self, *lines):
        return rules.convert("\n".join(("[Adblock Plus 2.0]", "! Title: fixture") + lines))

    def test_pure_hosts_group_into_request_domains(self):
        converted, skipped = self.convert("||ads.example.test^", "||Tracker.Example.TEST^", "||cdn.example.test^$third-party")
        self.assertEqual(skipped, {})
        conditions = [rule["condition"] for rule in converted]
        self.assertIn({"requestDomains": ["ads.example.test", "tracker.example.test"]}, conditions)
        self.assertIn({"domainType": "thirdParty", "requestDomains": ["cdn.example.test"]}, conditions)
        self.assertEqual([rule["id"] for rule in converted], [1, 2])

    def test_url_filters_options_and_exceptions(self):
        converted, _ = self.convert(
            "/pagead/js/adsbygoogle.js", "||example.test/ads/*$script,image,domain=a.test|~b.a.test",
            "@@||example.test/ads/ok.js$script", "@@||site.test^$document", "||example.test/x$~script,match-case",
            "||t.test/collect$important,method=post")
        by_filter = {rule["condition"].get("urlFilter"): rule for rule in converted}
        self.assertEqual(by_filter["/pagead/js/adsbygoogle.js"]["action"], {"type": "block"})
        scoped = by_filter["||example.test/ads/*"]["condition"]
        self.assertEqual(scoped["resourceTypes"], ["image", "script"])
        self.assertEqual(scoped["initiatorDomains"], ["a.test"])
        self.assertEqual(scoped["excludedInitiatorDomains"], ["b.a.test"])
        allow = by_filter["||example.test/ads/ok.js"]
        self.assertEqual((allow["action"]["type"], allow["priority"]), ("allow", rules.ALLOW_PRIORITY))
        document = next(rule for rule in converted if rule["action"]["type"] == "allowAllRequests")
        self.assertEqual(document["condition"], {"requestDomains": ["site.test"], "resourceTypes": ["main_frame", "sub_frame"]})
        negated = by_filter["||example.test/x"]["condition"]
        self.assertEqual(negated["excludedResourceTypes"], ["main_frame", "script"])
        self.assertTrue(negated["isUrlFilterCaseSensitive"])
        important = by_filter["||t.test/collect"]
        self.assertEqual(important["priority"], rules.IMPORTANT_PRIORITY)
        self.assertEqual(important["condition"]["requestMethods"], ["post"])
        rules.validate(converted)

    def test_unsupported_filters_are_skipped_not_approximated(self):
        converted, skipped = self.convert(
            "example.test##.ad", "##.banner", "@@||x.test^$generichide", "/ad[0-9]+/", "||pop.test^$popup",
            "||csp.test^$csp=script-src 'none'", "||doc.test^$document", "||w.test^$domain=example.*",
            "$third-party", "||r.test/a.js$redirect=noop.js")
        self.assertEqual(converted, [])
        self.assertEqual(skipped, {"cosmetic-exception": 1, "regex": 1, "option:popup": 1, "option:csp": 1,
                                   "document-block": 1, "domain-wildcard": 1, "too-broad": 1, "option:redirect": 1})

    def test_validation_rejects_invalid_rules(self):
        with self.assertRaises(SystemExit):
            rules.validate([{"id": 1, "priority": 1, "action": {"type": "block"}, "condition": {"urlFilter": "||*x"}}])
        with self.assertRaises(SystemExit):
            rules.validate([{"id": 1, "priority": 1, "action": {"type": "block"}, "condition": {"requestDomains": ["Bad Host"]}}])


class PinTests(unittest.TestCase):
    def test_committed_rulesets_match_the_pin_and_limits(self):
        self.assertLessEqual(rules.check(), rules.MAX_ENABLED_STATIC_RULES)

    def test_manifest_lists_both_rulesets_disabled(self):
        manifest = json.loads(rules.EXTENSION_MANIFEST.read_text())
        resources = manifest["declarative_net_request"]["rule_resources"]
        self.assertEqual([(entry["id"], entry["enabled"]) for entry in resources], [("easylist", False), ("easyprivacy", False)])
        self.assertEqual(manifest["permissions"], ["declarativeNetRequest", "cookies"])

    def test_generate_from_local_lists_and_detect_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "easylist.txt").write_text("[Adblock Plus 2.0]\n! Version: 202601020304\n||ads.example.test^\n")
            (root / "easyprivacy.txt").write_text("[Adblock Plus 1.1]\n! Version: 202601020305\n||t.example.test^$third-party\n")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"version": "0"}))
            pin = {"source": {"repository": "easylist/easylist", "branch": "gh-pages", "commit": "0" * 40,
                              "lists": {"easylist": {"path": "easylist.txt", "sha256": ""},
                                        "easyprivacy": {"path": "easyprivacy.txt", "sha256": ""}}}}
            output = root / "out"
            report = rules.generate(pin, root, output=output, manifest=manifest)
            self.assertEqual(report["easylist"]["rules"], 1)
            self.assertEqual(json.loads(manifest.read_text())["version"], "1.2601.0203.05")
            self.assertEqual(rules.check(pin, output=output), 2)
            (output / "easylist.json").write_text("[]\n")
            with self.assertRaises(SystemExit):
                rules.check(pin, output=output)
            (root / "easylist.txt").write_text("changed\n")
            with self.assertRaises(SystemExit):
                rules.generate(pin, root, output=output, manifest=manifest)


if __name__ == "__main__":
    unittest.main()
