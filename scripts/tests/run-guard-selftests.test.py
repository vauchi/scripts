#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Pre-push guard tests run and their process failures stop publication."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[1] / "run-guard-selftests.sh"
BASH = shutil.which("bash")


class GuardSelftestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_runner(self, root=None):
        return subprocess.run([BASH, str(RUNNER), str(root or self.root)],
                              capture_output=True, text=True)

    def test_executes_both_supported_guard_locations(self):
        for relative in ["scripts/tests/check-one.test.py", "ci/tests/check-two.test.py"]:
            test = self.root / relative
            test.parent.mkdir(parents=True, exist_ok=True)
            test.write_text("from pathlib import Path\n"
                            f"Path({str(test.with_suffix('.ran'))!r}).write_text('ran')\n", encoding="utf-8")
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.read_text(encoding="utf-8") for p in self.root.rglob("*.ran")),
                         ["ran", "ran"])
        self.assertIn("2 guard selftests completed", result.stdout)

    def test_failing_guard_stops_publication(self):
        test = self.root / "scripts/tests/check-failing.test.py"
        test.parent.mkdir(parents=True)
        test.write_text("import sys\nsys.stderr.write('injected guard failure\\n')\n"
                        "raise SystemExit(7)\n", encoding="utf-8")
        result = self.run_runner()
        self.assertEqual(result.returncode, 7)
        self.assertIn("injected guard failure", result.stderr)
        self.assertNotIn("selftests completed", result.stdout)

    def test_older_checkout_reports_no_registration(self):
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No guard selftests registered", result.stdout)

    def test_missing_repository_is_an_error(self):
        result = self.run_runner(root=self.root / "missing")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("selftests completed", result.stdout)


if __name__ == "__main__":
    unittest.main()
