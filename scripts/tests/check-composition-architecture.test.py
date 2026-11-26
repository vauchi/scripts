#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Seeded-violation tests for check-composition-architecture.py (#1415)."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parents[3]
CHECK = Path(__file__).resolve().parents[1] / "check-composition-architecture.py"
WORKSPACE_BASELINE = WORKSPACE / "scripts" / "composition-architecture-baseline.json"


def cargo(*dependencies: str) -> str:
    lines = ["[dependencies]"]
    lines.extend(f'{dependency} = "1"' for dependency in dependencies)
    return "\n".join(lines) + "\n"


REQUIRED_FILES = {
    "linux-app/Cargo.toml": cargo(
        "vauchi-core", "vauchi-app", "vauchi-contract", "vauchi-linux-hw", "gtk-display"
    ),
    "gtk-display/Cargo.toml": cargo("vauchi-contract"),
    "qt-display/CMakeLists.txt": "find_package(Qt6 REQUIRED)\n",
    "qt-display/contract-ref": "v0.98.0\n",
    "linux-hw/Cargo.toml": cargo("vauchi-contract"),
    "cli-display/Cargo.toml": cargo("vauchi-cli-display", "vauchi-core", "vauchi-app"),
    "cli-display/cli-display/Cargo.toml": cargo("vauchi-contract"),
    "tui-display/Cargo.toml": cargo("vauchi-contract"),
}

BASELINE = {
    "schema_version": 1,
    "exceptions": [{"path": "cli-display/Cargo.toml", "issue": "vauchi/private#1233"}],
}


class CompositionArchitectureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.baseline = self.root / "baseline.json"
        self.baseline.write_text(json.dumps(BASELINE), encoding="utf-8")
        (self.root / "qt-display/src").mkdir(parents=True, exist_ok=True)
        for relative, content in REQUIRED_FILES.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_check(self, root: Path | None = None, baseline: Path | None = None):
        return subprocess.run(
            [
                sys.executable,
                str(CHECK),
                "--root",
                str(root or self.root),
                "--baseline",
                str(baseline or self.baseline),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_failure(self, result, expected: str) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(expected, result.stdout + result.stderr)

    def write(self, relative: str, content: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def test_clean_fixture_passes(self) -> None:
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_current_workspace_has_no_new_violations(self) -> None:
        result = self.run_check(root=WORKSPACE, baseline=WORKSPACE_BASELINE)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_seeded_display_core_dependency_fails(self) -> None:
        self.write("gtk-display/Cargo.toml", cargo("vauchi-contract", "vauchi-core"))
        self.assert_failure(self.run_check(), "gtk-display/Cargo.toml")

    def test_seeded_hardware_core_dependency_fails(self) -> None:
        self.write("linux-hw/Cargo.toml", cargo("vauchi-contract", "vauchi-cabi"))
        self.assert_failure(self.run_check(), "linux-hw/Cargo.toml")

    def test_missing_required_repository_fails_closed(self) -> None:
        (self.root / "linux-hw/Cargo.toml").unlink()
        self.assert_failure(self.run_check(), "linux-hw/Cargo.toml")

    def test_missing_baseline_fails_closed(self) -> None:
        self.baseline.unlink()
        self.assert_failure(self.run_check(), "baseline")

    def test_malformed_baseline_fails_closed(self) -> None:
        self.baseline.write_text("{ not-json", encoding="utf-8")
        self.assert_failure(self.run_check(), "baseline")

    def test_unexpected_extra_exception_fails(self) -> None:
        document = dict(BASELINE)
        document["exceptions"] = BASELINE["exceptions"] + [
            {"path": "gtk-display/Cargo.toml", "issue": "vauchi/private#9999"}
        ]
        self.baseline.write_text(json.dumps(document), encoding="utf-8")
        self.assert_failure(self.run_check(), "unexpected exception")

    def test_baseline_removal_does_not_hide_root_core(self) -> None:
        self.baseline.write_text('{"schema_version": 1, "exceptions": []}', encoding="utf-8")
        self.assert_failure(self.run_check(), "cli-display/Cargo.toml")

    def test_future_cli_root_crate_removal_passes(self) -> None:
        self.baseline.write_text('{"schema_version": 1, "exceptions": []}', encoding="utf-8")
        self.write("cli-display/Cargo.toml", cargo("vauchi-cli-display"))
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_qt_core_ref_in_production_source_fails(self) -> None:
        self.write("qt-display/src/reader.cpp", '#include "core-ref"\n')
        self.assert_failure(self.run_check(), "production source")

    def test_linux_app_missing_hardware_shell_fails(self) -> None:
        self.write(
            "linux-app/Cargo.toml",
            cargo("vauchi-core", "vauchi-app", "vauchi-contract", "gtk-display"),
        )
        self.assert_failure(self.run_check(), "vauchi-linux-hw")


if __name__ == "__main__":
    unittest.main()
