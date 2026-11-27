#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""The standalone renderer has an exact-zero audit without app debt allowances."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "humble_check.py"
CONFIG = SCRIPTS / "humble_check_rules.json"


class AndroidDisplayHumble(unittest.TestCase):
    def fixture(self, base):
        module = base / "android-display"
        source = module / "src/main/kotlin/app/vauchi/ui/View.kt"
        source.parent.mkdir(parents=True)
        source.write_text("val prepared = true\n")
        return module, source

    def run_check(self, base, layout="standalone", extra=(), shim=None):
        root_args = ["--repo-path", str(base / "android-display")] if layout == "standalone" else ["--workspace-root", str(base)]
        args = [str(SCRIPT), "--repo", "android-display", *root_args, *extra]
        command = ["python3", "-c", shim, *args] if shim else ["python3", *args]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        return result.returncode, result.stdout + result.stderr

    def test_clean_renderer_passes_in_both_layouts(self):
        for layout in ("workspace", "standalone"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                self.fixture(base)
                status, output = self.run_check(base, layout)
                self.assertEqual(0, status, output)
                self.assertIn("all boundary counters are zero", output)

    def test_app_debt_and_exception_markers_cannot_excuse_library_violations(self):
        for layout in ("workspace", "standalone"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                _, source = self.fixture(base)
                source.write_text('// TODO(HUMBLE): app debt must not apply\nval action = "edit_avatar"\n')
                baseline = base / "baseline.json"
                baseline.write_text(json.dumps({"repos": {"android": {"action_id_minting": 100}}}))
                status, output = self.run_check(base, layout, ("--check", str(baseline)))
                self.assertEqual(1, status, output)
                self.assertIn("action_id_minting", output)

    def test_retired_boundary_scan_uses_the_actual_per_repo_sources(self):
        for layout in ("workspace", "standalone"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                _, source = self.fixture(base)
                source.write_text("val engine: AppEngine\n")
                status, output = self.run_check(base, layout)
                self.assertEqual(1, status, output)
                self.assertIn("retired_boundary_types", output)

    def test_missing_empty_or_excluded_sources_cannot_pass(self):
        for layout in ("workspace", "standalone"):
            for state in ("missing", "empty", "excluded"):
                with self.subTest(layout=layout, state=state), tempfile.TemporaryDirectory() as temp:
                    base = Path(temp)
                    module, source = self.fixture(base)
                    shutil.rmtree(module / "src")
                    if state != "missing":
                        (module / "src/main").mkdir(parents=True)
                    if state == "excluded":
                        excluded = module / "src/main/test/Fixture.kt"
                        excluded.parent.mkdir()
                        excluded.write_text("val prepared = true\n")
                    status, output = self.run_check(base, layout)
                    self.assertEqual(2, status, output)

    def test_linked_and_undecodable_inputs_cannot_pass(self):
        for state in ("linked-module", "linked-directory", "linked-file", "invalid-encoding"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                module, source = self.fixture(base)
                if state == "linked-module":
                    real = base / "real-module"
                    module.rename(real)
                    module.symlink_to(real, target_is_directory=True)
                elif state == "linked-directory":
                    real = base / "real-sources"
                    source.parent.rename(real)
                    source.parent.symlink_to(real, target_is_directory=True)
                elif state == "linked-file":
                    real = base / "Real.kt"
                    source.rename(real)
                    source.symlink_to(real)
                else:
                    source.write_bytes(b"val prepared = true\xff")
                status, output = self.run_check(base)
                self.assertEqual(2, status, output)

    def test_failed_source_enumeration_is_not_a_clean_result(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            self.fixture(base)
            shim = """import runpy, sys
from unittest.mock import patch
sys.argv = sys.argv[1:]
with patch('os.scandir', side_effect=OSError('injected source enumeration failure')):
    runpy.run_path(sys.argv[0], run_name='__main__')
"""
            status, output = self.run_check(base, shim=shim)
            self.assertEqual(2, status, output)
            self.assertIn("injected source enumeration failure", output)

    def test_registered_app_gate_keeps_its_sources_and_budget(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            self.fixture(base)
            app = base / "android/app/src/main/kotlin/Host.kt"
            app.parent.mkdir(parents=True)
            app.write_text('val action = "edit_avatar"\n')
            baseline = base / "baseline.json"
            baseline.write_text(json.dumps({"repos": {"android": {"action_id_minting": 1}}}))
            args = ["python3", str(SCRIPT), "--repo", "android", "--repo-path", str(base / "android"), "--check", str(baseline)]
            result = subprocess.run(args, capture_output=True, text=True, check=False)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            baseline.write_text(json.dumps({"repos": {"android": {}}}))
            result = subprocess.run(args, capture_output=True, text=True, check=False)
            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertIn("action_id_minting", result.stdout + result.stderr)

    def test_workspace_zero_gate_still_rejects_registered_app_debt(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            self.fixture(base)
            app = base / "android/app/src/main/Host.kt"
            app.parent.mkdir(parents=True)
            app.write_text("val prepared = true\n")
            config = json.loads(CONFIG.read_text())
            config["repos"] = {"android": config["repos"]["android"]}
            config_path = base / "rules.json"
            config_path.write_text(json.dumps(config))
            baseline = base / "baseline.json"
            baseline.write_text(json.dumps({"repos": {"android": {"action_id_minting": 1}}}))
            result = subprocess.run(["python3", str(SCRIPT), "--workspace-root", str(base), "--config", str(config_path), "--check", str(baseline), "--release-zero"], capture_output=True, text=True, check=False)
            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertIn("android.action_id_minting", result.stdout + result.stderr)

    def test_standalone_profile_cannot_replace_a_registered_app(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            self.fixture(base)
            app = base / "android/app/src/main/Host.kt"
            app.parent.mkdir(parents=True)
            app.write_text('val action = "edit_avatar"\n')
            config = json.loads(CONFIG.read_text())
            config["standalone_repos"] = {"android": {"rules_from": "android", "source_roots": ["android-display/src/main"]}}
            config_path = base / "rules.json"
            config_path.write_text(json.dumps(config))
            result = subprocess.run(["python3", str(SCRIPT), "--repo", "android", "--workspace-root", str(base), "--config", str(config_path)], capture_output=True, text=True, check=False)
            self.assertEqual(2, result.returncode, result.stdout + result.stderr)
            self.assertIn("registered", result.stdout + result.stderr)

    def test_standalone_profile_cannot_store_its_own_debt(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            self.fixture(base)
            baseline = base / "baseline.json"
            baseline.write_text(json.dumps({"repos": {"android-display": {"action_id_minting": 1}}}))
            status, output = self.run_check(base, extra=("--check", str(baseline)))
            self.assertEqual(1, status, output)
            self.assertIn("action_id_minting", output)

    def test_standalone_profile_cannot_run_a_workspace_baseline_sweep(self):
        for mode in ("--release-zero", "--tighten"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                self.fixture(base)
                baseline = base / "baseline.json"
                baseline.write_text('{"repos": {}}')
                args = (mode, str(baseline)) if mode == "--tighten" else (mode, "--check", str(baseline))
                status, output = self.run_check(base, extra=args)
                self.assertEqual(2, status, output)
                self.assertIn("standalone repos", output)

    def test_registered_repo_retired_boundary_uses_the_real_root(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            config = json.loads(CONFIG.read_text())
            for relative in config["repos"]["ios"]["source_roots"]:
                directory = base / relative
                directory.mkdir(parents=True, exist_ok=True)
            source = base / config["repos"]["ios"]["source_roots"][0] / "View.swift"
            source.write_text("class View { var engine: AppEngine }\n")
            result = subprocess.run(["python3", str(SCRIPT), "--repo", "ios", "--repo-path", str(base / "ios"), "--config", str(CONFIG), "--require-zero"], capture_output=True, text=True, check=False)
            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertIn("retired_boundary_types", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
