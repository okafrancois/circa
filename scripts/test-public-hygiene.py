#!/usr/bin/env python3
"""Regression tests for the publication policy, run by the Swift test suite."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("public_hygiene", Path(__file__).with_name("check-public-hygiene.py"))
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


class PublicHygieneTests(unittest.TestCase):
    def test_mentions_and_paths(self):
        name = policy.SOURCE_NAME
        for value in (name, name.lower(), name.upper(), name.swapcase(), name + "Sidebar",
                      "quit" + name, "uses_" + name.lower(), "uses_" + name.lower() + "_data",
                      "Old" + name + "yBridge", "source_" + name.lower() + "_asset", name.lower() + "y_engine",
                      policy.SOURCE_BUNDLE_ID):
            with self.subTest(value=value):
                self.assertTrue(policy.check_text("native/example.swift", "// " + value))
        self.assertTrue(policy.check_path(f"native/{name}Sidebar.swift"))
        self.assertFalse(policy.check_path(policy.IMPORT_ROOTS[0] + f"{name}Importer.swift"))
        self.assertFalse(policy.check_text("example.swift", "Archive arch arc4random() search hierarchy"))

    def test_import_exceptions_are_exact(self):
        name = policy.SOURCE_NAME
        path = "native/Sources/Orbit/App/EngineComposition.swift"
        identifier = name + "SiteSessionResult"
        self.assertFalse(policy.check_text(path, f"var result: {identifier}?"))
        self.assertTrue(policy.check_text(path, f"// {name} sidebar"))
        self.assertTrue(policy.check_text(path, identifier + "Sidebar"))
        self.assertTrue(policy.check_text("other.swift", identifier))
        imported = policy.IMPORT_ROOTS[0] + "Example.swift"
        self.assertFalse(policy.check_text(imported, f"Import {name} data"))
        self.assertTrue(policy.check_text(imported, "// 0x" + "123456789"))
        self.assertTrue(policy.check_text(imported, "// pa" + "rity"))

    def test_localized_import_keys(self):
        key = "Import from " + policy.SOURCE_NAME + "…"
        literal = json.dumps(key, ensure_ascii=False)
        line = f"{literal} = {literal};"
        self.assertFalse(policy.check_text(policy.LOCALIZATION_PATH, line))
        self.assertTrue(policy.check_text(policy.LOCALIZATION_PATH, line + " // " + policy.SOURCE_NAME))
        self.assertTrue(policy.check_text(policy.LOCALIZATION_PATH, line.replace("Import from", "Styled like")))
        self.assertTrue(policy.check_text("unrelated.strings", line))

    def test_addresses_and_api_constants(self):
        for digits in ("123456789", "0000000123456789", "12345678", "7ff0abcdef12"):
            self.assertTrue(policy.check_text("example.swift", "// 0x" + digits))
        for path, values in policy.ALLOWED_HEX.items():
            for digits in values:
                self.assertFalse(policy.check_text(path, "0x" + digits))
                self.assertTrue(policy.check_text("unrelated.swift", "0x" + digits))
        self.assertFalse(policy.check_text("example.swift", "let color = 0xABCDEF"))
        self.assertFalse(policy.check_text("CMakeLists.txt", policy.TECHNICAL_TEXT[0]))
        self.assertFalse(policy.check_text("geometry.swift", policy.TECHNICAL_TEXT[1] + "(withCenter: point)"))

    def test_compatibility_is_localized(self):
        path = "native/OrbitChromium/Bridge/EngineCompatibility.h"
        symbol = policy.SOURCE_NAME.lower() + "y_cef_get_api"
        self.assertFalse(policy.check_text(path, '"' + symbol + '"'))
        self.assertTrue(policy.check_text("other.h", symbol))

    def test_tracked_tree_and_binary_metadata(self):
        with tempfile.TemporaryDirectory(prefix="orbit-hygiene-") as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            (root / "lab").mkdir()
            (root / "lab/note.md").write_text("private local note")
            (root / "image.dat").write_bytes(b"\x89\xff" + ("asset from " + policy.SOURCE_NAME).encode() + b"\x00")
            self.assertEqual(policy.check_repository(root), [])
            subprocess.run(["git", "-C", str(root), "add", "--force", "lab/note.md", "image.dat"], check=True)
            findings = policy.check_repository(root)
            self.assertEqual({row[0] for row in findings}, {"lab/note.md", "image.dat"})
            (root / "image.dat").write_bytes(b"\x89\xff" + b"0x" + b"123456789" + b"\x00")
            self.assertTrue(any(row[2] == "binary address pattern" for row in policy.check_repository(root)))
            self.assertTrue(policy.check_path("nested/lab/note.md"))


if __name__ == "__main__":
    unittest.main()
