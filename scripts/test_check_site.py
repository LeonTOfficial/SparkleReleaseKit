#!/usr/bin/env python3

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_site import local_target, terminal_text


class SiteValidatorTests(unittest.TestCase):
    def test_rejects_symbolic_link_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory) / "website"
            site.mkdir()
            page = site / "index.html"
            page.write_text("<main></main>", encoding="utf-8")
            target = site / "target.txt"
            target.write_text("target", encoding="utf-8")
            (site / "alias.txt").symlink_to(target)

            with self.assertRaisesRegex(ValueError, "symbolic link"):
                local_target(page, "alias.txt", site)

    def test_rejects_escaping_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory) / "website"
            site.mkdir()
            page = site / "index.html"

            with self.assertRaisesRegex(ValueError, "escapes website root"):
                local_target(page, "../outside.txt", site)

    def test_neutralizes_terminal_and_bidi_controls(self) -> None:
        value = "safe\u001b[31m\u202eright-to-left\nnext"

        sanitized = terminal_text(value)

        self.assertNotIn("\u001b", sanitized)
        self.assertNotIn("\u202e", sanitized)
        self.assertNotIn("\n", sanitized)
        self.assertIn("\\u{1B}", sanitized)
        self.assertIn("\\u{202E}", sanitized)
        self.assertIn("\\u{A}", sanitized)


if __name__ == "__main__":
    unittest.main()
