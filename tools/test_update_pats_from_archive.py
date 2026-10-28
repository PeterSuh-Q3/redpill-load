#!/usr/bin/env python3
"""Offline tests for explicit DSM release intake."""

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("update_pats_from_archive.py")
spec = importlib.util.spec_from_file_location("update_pats_from_archive", SCRIPT)
intake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(intake)


class ReleaseIntakeTests(unittest.TestCase):
    def test_accepts_future_three_component_release(self):
        self.assertEqual(intake.validate_release("7.4.2-99999"), "7.4.2-99999")
        self.assertEqual(intake.version_key("7.4.2-99999"), "7.4.2-99999-0")

    def test_accepts_two_component_archive_release(self):
        self.assertEqual(intake.validate_release("7.4-90075"), "7.4-90075")
        self.assertEqual(intake.version_key("7.4-90075"), "7.4.0-90075-0")

    def test_rejects_non_numeric_or_incomplete_release(self):
        for release in ("7.4.2", "7.4.x-99999", "7.4.2-", "7.4.2-99999/extra"):
            with self.subTest(release=release), self.assertRaises(ValueError):
                intake.validate_release(release)

    def test_collects_exact_model_from_unlisted_release(self):
        html = '<a href="https://global.synologydownload.com/download/DSM/release/7.4.2/99999/DSM_SA6400_99999.pat">PAT</a>'
        with patch.object(intake, "fetch", return_value=html):
            self.assertEqual(
                intake.collect("7.4.2-99999", {"SA6400"}),
                [("SA6400", "7.4.2-99999-0", "https://global.synologydownload.com/download/DSM/release/7.4.2/99999/DSM_SA6400_99999.pat")],
            )


if __name__ == "__main__":
    unittest.main()
