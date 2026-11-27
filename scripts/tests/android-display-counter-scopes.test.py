#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Exercise vocabulary and LOC ownership through their shipped CLIs."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
COUNTERS = {
    "vocab": ("audit-frontend-vocab.sh", "nav_domain_literals_android", 'navigateTo("Contacts")\n', "nav_domain_literals_total"),
    "loc": ("loc-budget.sh", "android_handwritten_loc", "val value = 1\n", "handwritten_loc_total"),
}
KOTLIN = Path("src/main/kotlin/app/vauchi/ui")


class AndroidDisplayCounterScopes(unittest.TestCase):
    def environment(self, extra=None):
        env = os.environ.copy()
        env.pop("VAUCHI_ANDROID_DISPLAY_ROOT", None)
        env.update(extra or {})
        return env

    def source(self, module, kind, repeats=1, filename="Counter.kt"):
        path = module / KOTLIN / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(COUNTERS[kind][2] * repeats)
        return path

    def fixture(self, base, kind, standalone=False):
        workspace = base / "workspace"
        module = workspace / "android-display"
        self.source(module, kind)
        (module / "settings.gradle.kts").write_text('rootProject.name = "android-display"\n')
        if not standalone:
            self.source(workspace / "android/app", kind)
        return module if standalone else workspace, module

    def run_counter(self, root, kind, baseline=None, env=None):
        args = ["bash", str(SCRIPTS / COUNTERS[kind][0])]
        if baseline is not None:
            args += ["--check", str(baseline)]
        args += [str(root)]
        return subprocess.run(args, capture_output=True, text=True, env=self.environment(env), check=False)

    def assert_count(self, root, kind, expected, env=None):
        result = self.run_counter(root, kind, env=env)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(expected, json.loads(result.stdout)["totals"][COUNTERS[kind][1]])

    def test_independent_sources_and_exclusions(self):
        for kind in COUNTERS:
            for standalone in (False, True):
                with self.subTest(kind=kind, standalone=standalone), tempfile.TemporaryDirectory() as temp:
                    root, module = self.fixture(Path(temp), kind, standalone)
                    self.source(module, kind, filename="Generated/Extra.kt")
                    self.source(module, kind, filename="Libs/Extra.kt")
                    self.source(module, kind, filename="Tests/Extra.kt")
                    excluded = module / "src/test/kotlin/Probe.kt"
                    excluded.parent.mkdir(parents=True)
                    excluded.write_text(COUNTERS[kind][2])
                    self.assert_count(root, kind, 1 if standalone else 2)

    def test_active_in_place_sources_remain_counted(self):
        for kind in COUNTERS:
            for active in (False, True):
                with self.subTest(kind=kind, active=active), tempfile.TemporaryDirectory() as temp:
                    root, _ = self.fixture(Path(temp), kind)
                    self.source(root / "android/display", kind, repeats=3)
                    if active:
                        (root / "android/settings.gradle.kts").write_text('include(":app", ":display")\n')
                    self.assert_count(root, kind, 5 if active else 2)

    def test_app_and_in_place_workspace_or_direct_layout(self):
        for kind in COUNTERS:
            for direct in (False, True):
                with self.subTest(kind=kind, direct=direct), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp) / "workspace"
                    app = root / "android"
                    self.source(app / "app", kind)
                    self.source(app / "display", kind)
                    (app / "settings.gradle.kts").write_text('include(":app", ":display")\n')
                    self.assert_count(app if direct else root, kind, 2)

    def test_renamed_app_and_explicit_checkout_with_spaces(self):
        for kind in COUNTERS:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                root, module = self.fixture(base, kind)
                (root / "android").rename(root / "android-app")
                outside = base / "separate renderer"
                module.rename(outside)
                source = outside / KOTLIN / "Counter.kt"
                source.rename(source.with_name("Counter with spaces.kt"))
                self.assert_count(root, kind, 2, {"VAUCHI_ANDROID_DISPLAY_ROOT": str(outside)})

    def test_missing_empty_linked_or_invalid_sources_fail(self):
        for kind in COUNTERS:
            for state in ("missing", "empty", "excluded-only", "linked-file", "linked-main", "linked-module", "encoding"):
                with self.subTest(kind=kind, state=state), tempfile.TemporaryDirectory() as temp:
                    base = Path(temp)
                    root, module = self.fixture(base, kind)
                    source = module / KOTLIN / "Counter.kt"
                    if state == "missing":
                        shutil.rmtree(module / "src")
                    elif state == "empty":
                        source.unlink()
                    elif state == "excluded-only":
                        generated = source.parent / "Generated"
                        generated.mkdir()
                        source.rename(generated / source.name)
                    elif state == "linked-file":
                        outside = base / "Outside.kt"
                        source.rename(outside)
                        source.symlink_to(outside)
                    elif state == "linked-main":
                        outside = base / "outside"
                        (module / "src/main").rename(outside)
                        (module / "src/main").symlink_to(outside, target_is_directory=True)
                    elif state == "linked-module":
                        outside = base / "outside"
                        module.rename(outside)
                        module.symlink_to(outside, target_is_directory=True)
                    else:
                        source.write_bytes(b"invalid source\xff")
                    result = self.run_counter(root, kind)
                    self.assertEqual(2, result.returncode, result.stdout + result.stderr)
                    self.assertIn("source", result.stderr.lower())

    def test_declared_or_external_modules_are_required(self):
        for kind in COUNTERS:
            for state in ("declared-missing", "declared-empty", "external-missing", "external-empty"):
                with self.subTest(kind=kind, state=state), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp) / "workspace"
                    self.source(root / "android/app", kind)
                    env = {}
                    if state.startswith("declared"):
                        (root / "android/settings.gradle.kts").write_text('include(":app", ":display")\n')
                        if state.endswith("empty"):
                            (root / "android/display/src/main").mkdir(parents=True)
                    else:
                        env["VAUCHI_ANDROID_DISPLAY_ROOT"] = str(root / "missing") if state.endswith("missing") else ""
                    result = self.run_counter(root, kind, env=env)
                    self.assertEqual(2, result.returncode, result.stdout + result.stderr)

    def test_aggregate_counter_still_enforces_unchanged_budget(self):
        for kind, (_, key, _, total) in COUNTERS.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                root, _ = self.fixture(base, kind)
                baseline = base / "baseline.json"
                baseline.write_text(json.dumps({"totals": {key: 1, total: 1}}))
                result = self.run_counter(root, kind, baseline)
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertIn(key, result.stderr)

    def test_scanner_errors_fail_instead_of_becoming_zero(self):
        for kind in COUNTERS:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                root, _ = self.fixture(base, kind)
                tools = base / "tools"
                tools.mkdir()
                grep = tools / "grep"
                grep.write_text('#!/bin/sh\nprintf "injected scanner refusal\\n" >&2\nexit 2\n')
                grep.chmod(0o755)
                result = self.run_counter(root, kind, env={"PATH": str(tools) + os.pathsep + os.environ["PATH"]})
                self.assertEqual(2, result.returncode, result.stdout + result.stderr)
                self.assertIn("injected scanner refusal", result.stderr)

    def test_vocabulary_retains_legacy_non_kotlin_matching(self):
        for kind in COUNTERS:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp) / "workspace"
                source = self.source(root / "android/app", kind)
                source.with_name("notes.txt").write_text('navigateTo("Contacts")\n')
                self.assert_count(root, kind, 2 if kind == "vocab" else 1)

    def test_inventory_rejects_a_nonexistent_workspace(self):
        with tempfile.TemporaryDirectory() as temp:
            result = subprocess.run(
                ["python3", str(SCRIPTS / "android-audit-sources.py"), str(Path(temp) / "missing")],
                capture_output=True, text=True, env=self.environment(), check=False,
            )
            self.assertEqual(2, result.returncode, result.stdout + result.stderr)
            self.assertIn("workspace", result.stderr)

    def test_direct_declared_module_does_not_require_an_app_tree(self):
        for kind in COUNTERS:
            for present in (False, True):
                with self.subTest(kind=kind, present=present), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp) / "android"
                    root.mkdir()
                    (root / "settings.gradle.kts").write_text('include(":display")\n')
                    if present:
                        self.source(root / "display", kind)
                        self.assert_count(root, kind, 1)
                    else:
                        result = self.run_counter(root, kind)
                        self.assertEqual(2, result.returncode, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
