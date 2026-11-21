#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""last-used.py: when each skill and recipe was last run (vauchi/private#1198)."""
import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "last_used", SCRIPT_DIR / "last-used.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def event(ts, category, **fields):
    return json.dumps({"ts": ts, "hook": "x", "category": category, **fields})


class TallyTests(unittest.TestCase):
    def test_keeps_the_latest_date_and_the_count_per_name(self):
        lines = [
            event("2026-11-01T10:00:00Z", "skill-use", skill="markdown-lint"),
            event("2026-11-09T10:00:00Z", "skill-use", skill="markdown-lint"),
            event("2026-11-03T10:00:00Z", "just-use", recipe="check"),
            event("2026-11-02T10:00:00Z", "just-use", recipe="gitlab::mr-ready"),
            event("2026-11-04T10:00:00Z", "git-silence", reason="VGT01-pipe"),
            "not json",
        ]
        tally = MODULE.tally(lines)
        self.assertEqual(tally["skill"], {"markdown-lint": ("2026-11-09", 2)})
        self.assertEqual(tally["recipe"], {
            "check": ("2026-11-03", 1), "gitlab::mr-ready": ("2026-11-02", 1)})

    def test_names_what_was_never_used(self):
        tally = MODULE.tally([event("2026-11-03T10:00:00Z", "just-use", recipe="check")])
        report = MODULE.render(tally, skills=["markdown-lint", "ci-fix"],
                               recipes=["check", "build"])
        self.assertIn("skill  markdown-lint  never", report)
        self.assertIn("skill  ci-fix  never", report)
        self.assertIn("recipe  check  2026-11-03  1", report)
        self.assertIn("recipe  build  never", report)

    def test_reads_every_slot_log_it_is_given(self):
        with tempfile.TemporaryDirectory() as tmp:
            a = Path(tmp) / "a.log"
            b = Path(tmp) / "b.log"
            a.write_text(event("2026-11-01T10:00:00Z", "skill-use", skill="s") + "\n", encoding="utf-8")
            b.write_text(event("2026-11-05T10:00:00Z", "skill-use", skill="s") + "\n", encoding="utf-8")
            tally = MODULE.tally(MODULE.read_logs([a, b]))
        self.assertEqual(tally["skill"]["s"], ("2026-11-05", 2))

    def test_main_prints_the_report_sorted_oldest_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / ".session-errors"
            log.write_text("\n".join([
                event("2026-11-05T10:00:00Z", "just-use", recipe="new"),
                event("2026-10-01T10:00:00Z", "just-use", recipe="old"),
            ]) + "\n", encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                code = MODULE.main(["--log", str(log), "--skills", "", "--recipes", "old,new,never"])
        self.assertEqual(code, 0)
        text = out.getvalue()
        self.assertLess(text.index("never"), text.index("old"))
        self.assertLess(text.index("old"), text.index("new"))


if __name__ == "__main__":
    unittest.main()
