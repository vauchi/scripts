#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Exercise the real Python/Rust protocol in a separate tool installation."""

import json
import shutil
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(SCRIPTS / "scripts/tests"))
from quality_scan_fixture import ScanFixture  # noqa: E402

REAL_HELPER = SCRIPTS / "tools/architecture-check/target/debug/vauchi-quality-complexity"


class RealComplexityTests(ScanFixture):
    def setUp(self):
        super().setUp()
        self.helper.parent.mkdir(parents=True)
        shutil.copyfile(REAL_HELPER, self.helper)
        self.helper.chmod(0o755)

    def test_actual_backend_reports_scores_and_matching_protocol_version(self):
        self.tracked(self.root, "known.rs", "fn flat() { if a {} if b {} }\n"
                     "fn nested() { if a { if b {} } }\n")
        data = self.report("--complexity")["complexity"]
        self.assertEqual(data["formula_version"], 1)
        self.assertEqual(data["analyzed_paths"], ["known.rs"])
        self.assertEqual([(f["name"], f["cyclomatic"], f["max_nesting"])
                          for f in data["functions"]], [("flat", 3, 1), ("nested", 3, 2)])

    def test_actual_parser_error_preserves_partial_report_and_failure_status(self):
        self.tracked(self.root, "broken.rs", "fn incomplete(\n")
        result = self.run_scan("--complexity", "--json")
        self.assertEqual(result.returncode, 2)
        data = json.loads(result.stdout)["complexity"]
        self.assertEqual(data["analyzed_paths"], [])
        self.assertEqual(data["failures"][0]["path"], "broken.rs")
        self.assertIn("incomplete", result.stderr)

    def test_types_only_and_empty_files_are_valid_without_functions(self):
        self.tracked(self.root, "types.rs", "struct Value;\n")
        self.tracked(self.root, "empty.rs", "")
        data = self.report("--complexity")["complexity"]
        self.assertEqual(data["analyzed_paths"], ["empty.rs", "types.rs"])
        self.assertEqual(data["files_analyzed"], 2)
        self.assertEqual(data["functions"], [])
        self.assertEqual(data["failures"], [])


if __name__ == "__main__":
    unittest.main()
