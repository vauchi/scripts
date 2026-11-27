#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Exercise the shipped text audit through its command-line interface."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "audit-frontend-i18n-strings.sh"
KOTLIN = Path("src/main/kotlin/app/vauchi/ui")


class AndroidDisplayTextScopes(unittest.TestCase):
    def write_source(self, module, text='Text("Hello world")\n'):
        source = module / KOTLIN / "Screen.kt"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(text)
        return source

    def fixture(self, base, standalone=False):
        workspace = base / "workspace"
        module = workspace / "android-display"
        self.write_source(module)
        (module / "settings.gradle.kts").write_text(
            'rootProject.name = "android-display"\n'
        )
        if not standalone:
            self.write_source(workspace / "android/app", 'Text("App title")\n')
        return module if standalone else workspace, module

    def run_audit(self, root, baseline=None, env=None):
        args = ["bash", str(SCRIPT)]
        if baseline is not None:
            args += ["--check", str(baseline)]
        args += [str(root)]
        return subprocess.run(args, capture_output=True, text=True, env=env, check=False)

    def assert_count(self, root, expected, env=None):
        result = self.run_audit(root, env=env)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(expected, json.loads(result.stdout)["totals"]["android"])

    def test_independent_sources_count_in_workspace_and_standalone(self):
        for standalone in (False, True):
            with self.subTest(standalone=standalone), tempfile.TemporaryDirectory() as temp:
                root, module = self.fixture(Path(temp), standalone)
                self.assert_count(root, 1 if standalone else 2)
                (module / "src/test/kotlin").mkdir(parents=True)
                (module / "src/test/kotlin/Probe.kt").write_text('Text("Fixture label")\n')
                self.assert_count(root, 1 if standalone else 2)

    def test_independent_sources_replace_stale_in_place_copy(self):
        with tempfile.TemporaryDirectory() as temp:
            root, _ = self.fixture(Path(temp))
            self.write_source(root / "android/display", 'Text("Stale label")\n' * 3)
            self.assert_count(root, 2)

    def test_existing_app_and_in_place_layouts_stay_counted(self):
        for direct in (False, True):
            with self.subTest(direct=direct), tempfile.TemporaryDirectory() as temp:
                workspace = Path(temp) / "workspace"
                app = workspace / "android"
                self.write_source(app / "app")
                self.write_source(app / "display")
                (app / "settings.gradle.kts").write_text('include(":app", ":display")\n')
                self.assert_count(app if direct else workspace, 2)

    def test_declared_in_place_sources_cannot_hide_behind_independent_copy(self):
        with tempfile.TemporaryDirectory() as temp:
            root, _ = self.fixture(Path(temp))
            self.write_source(root / "android/display", 'Text("Active app label")\n' * 3)
            (root / "android/settings.gradle.kts").write_text('include(":app", ":display")\n')
            self.assert_count(root, 5)

    def test_renamed_app_retains_counts_alongside_independent_display(self):
        with tempfile.TemporaryDirectory() as temp:
            root, _ = self.fixture(Path(temp))
            (root / "android").rename(root / "android-app")
            self.assert_count(root, 2)

    def test_missing_empty_linked_or_invalid_display_sources_fail(self):
        for standalone in (False, True):
            for state in ("missing", "empty", "linked-file", "linked-main", "linked-module", "encoding"):
                with self.subTest(standalone=standalone, state=state), tempfile.TemporaryDirectory() as temp:
                    base = Path(temp)
                    root, module = self.fixture(base, standalone)
                    source = module / KOTLIN / "Screen.kt"
                    if state == "missing":
                        shutil.rmtree(module / "src")
                    elif state == "empty":
                        source.unlink()
                    elif state == "linked-file":
                        outside = base / "Outside.kt"
                        outside.write_text(source.read_text())
                        source.unlink()
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
                        source.write_bytes(b'Text("Hello world")\n\xff')
                    result = self.run_audit(root)
                    self.assertEqual(2, result.returncode, result.stdout + result.stderr)
                    self.assertIn("source", result.stderr.lower())

    def test_declared_module_or_external_checkout_is_required(self):
        for state in ("declared-missing", "declared-empty", "external-missing", "external-empty"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temp:
                root = Path(temp) / "workspace"
                self.write_source(root / "android/app")
                env = os.environ.copy()
                if state.startswith("declared"):
                    (root / "android/settings.gradle.kts").write_text('include(":app", ":display")\n')
                    if state.endswith("empty"):
                        (root / "android/display/src/main").mkdir(parents=True)
                else:
                    env["VAUCHI_ANDROID_DISPLAY_ROOT"] = str(root / "missing") if state.endswith("missing") else ""
                result = self.run_audit(root, env=env)
                self.assertEqual(2, result.returncode, result.stdout + result.stderr)

    def test_explicit_checkout_and_ratchet_reject_hidden_literal(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root, module = self.fixture(base)
            outside = base / "separate renderer"
            module.rename(outside)
            env = {**os.environ, "VAUCHI_ANDROID_DISPLAY_ROOT": str(outside)}
            self.assert_count(root, 2, env)
            baseline = base / "baseline.json"
            baseline.write_text(json.dumps({"totals": {"android": 0, "total": 0}}))
            result = self.run_audit(root, baseline, env)
            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertIn("android rose to 2", result.stderr)

    def test_scanner_error_is_not_a_zero_count(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            root, _ = self.fixture(base)
            tools = base / "tools"
            tools.mkdir()
            grep = tools / "grep"
            grep.write_text('#!/bin/sh\nprintf "injected scanner failure\\n" >&2\nexit 2\n')
            grep.chmod(0o755)
            result = self.run_audit(root, env={**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"]})
            self.assertEqual(2, result.returncode, result.stdout + result.stderr)
            self.assertIn("injected scanner failure", result.stderr)

    def test_source_read_and_enumeration_errors_fail(self):
        patches = {
            "enumeration": '''import os
original = os.scandir
def refused(path):
    if str(path).endswith("android-display/src/main"):
        raise PermissionError("injected enumeration refusal")
    return original(path)
os.scandir = refused
''',
            "read": '''import io
original = io.open
def refused(path, *args, **kwargs):
    if str(path).endswith("Screen.kt"):
        raise PermissionError("injected source read refusal")
    return original(path, *args, **kwargs)
io.open = refused
''',
        }
        for kind, patch in patches.items():
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                root, _ = self.fixture(base)
                hooks = base / "hooks"
                hooks.mkdir()
                (hooks / "sitecustomize.py").write_text(patch)
                result = self.run_audit(root, env={**os.environ, "PYTHONPATH": str(hooks)})
                self.assertEqual(2, result.returncode, result.stdout + result.stderr)
                self.assertIn("injected", result.stderr)


if __name__ == "__main__":
    unittest.main()
