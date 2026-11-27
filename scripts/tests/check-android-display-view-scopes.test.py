#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""View audits must follow the renderer and reject incomplete scans."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
GUARDS = (
    ("check-no-isimported-in-views.sh", "val visible = row.isImported", ()),
    ("check-no-domain-conditionals-in-views.sh", "val verified = row.isVerified", ()),
    ("check-no-direct-clipboard-writes.sh", "clipboard.setPrimaryClip(value)", ()),
    ("check-no-domain-imports-in-views.sh", "import uniffi.vauchi_platform.MobileContact", ("--strict",)),
)


class AndroidDisplayViewScopes(unittest.TestCase):
    def fixture(self, root, layout):
        repo = root / "android"
        app = repo / "app/src/main/kotlin/app/vauchi/ui"
        display = repo / "display/src/main/kotlin/app/vauchi/ui"
        app.mkdir(parents=True)
        display.mkdir(parents=True)
        (repo / "settings.gradle.kts").write_text('include(":app", ":display")\n')
        (app / "Host.kt").write_text("val prepared = true\n")
        return (root if layout == "workspace" else repo), app, display

    def run_guard(self, guard, root, args, env=None):
        result = subprocess.run(
            ["bash", str(SCRIPTS / guard), str(root), *args],
            capture_output=True, text=True, env=env, check=False,
        )
        return result.returncode, result.stdout + result.stderr

    def test_library_violations_cannot_hide_behind_the_app(self):
        for layout in ("workspace", "repo"):
            for guard, sentinel, args in GUARDS:
                with self.subTest(layout=layout, guard=guard), tempfile.TemporaryDirectory() as temp:
                    root, _, display = self.fixture(Path(temp), layout)
                    source = display / "BadView.kt"
                    source.write_text(sentinel + "\n")
                    status, output = self.run_guard(guard, root, args)
                    self.assertEqual(1, status, output)
                    self.assertIn(str(source), output)

    def test_declared_library_views_cannot_be_empty_or_deleted(self):
        for layout in ("workspace", "repo"):
            for guard, _, args in GUARDS:
                for missing in ("empty", "deleted"):
                    with self.subTest(layout=layout, guard=guard, missing=missing), tempfile.TemporaryDirectory() as temp:
                        root, _, display = self.fixture(Path(temp), layout)
                        if missing == "deleted":
                            shutil.rmtree(display.parents[5])
                        status, output = self.run_guard(guard, root, args)
                        self.assertEqual(2, status, output)

    def test_content_scan_errors_are_not_clean_results(self):
        real_rg = shutil.which("rg")
        self.assertIsNotNone(real_rg)
        for guard, _, args in GUARDS:
            with self.subTest(guard=guard), tempfile.TemporaryDirectory() as temp:
                root, _, display = self.fixture(Path(temp), "repo")
                (display / "View.kt").write_text("val prepared = true\n")
                tools = Path(temp) / "tools"
                tools.mkdir()
                stub = tools / "rg"
                # Fail content reads after inventory and identity discovery succeed.
                stub.write_text('#!/bin/sh\nif [ "$1" = "--files" ] || [ "$1" = "--quiet" ]; then exec ' + shlex.quote(real_rg) + ' "$@"; fi\nexit 2\n')
                stub.chmod(0o755)
                env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"])
                status, output = self.run_guard(guard, root, args, env)
                self.assertEqual(2, status, output)
                self.assertIn("could not complete the view scan", output)

    def test_app_composition_allowlists_do_not_exempt_display_code(self):
        with tempfile.TemporaryDirectory() as temp:
            root, app, display = self.fixture(Path(temp), "repo")
            for tree in (app, display):
                (tree / "coreui").mkdir()
                (tree / "coreui/Bridge.kt").write_text("import uniffi.vauchi_platform.MobileContact\n")
            status, output = self.run_guard("check-no-domain-imports-in-views.sh", root, ("--strict",))
            self.assertEqual(1, status, output)
            self.assertIn(str(display / "coreui/Bridge.kt"), output)
            self.assertNotIn(str(app / "coreui/Bridge.kt") + ":", output)

    def independent_fixture(self, root, layout):
        module = root / "android-display"
        views = module / "src/main/kotlin/app/vauchi/ui"
        views.mkdir(parents=True)
        (module / "settings.gradle.kts").write_text('rootProject.name = "android-display"\n')
        if layout == "workspace":
            self.fixture(root, "workspace")[2].joinpath("View.kt").write_text("val prepared = true\n")
        return (root if layout == "workspace" else module), module, views

    def test_independent_library_is_scanned_without_app_exemptions(self):
        for layout in ("workspace", "standalone"):
            for guard, sentinel, args in GUARDS:
                with self.subTest(layout=layout, guard=guard), tempfile.TemporaryDirectory() as temp:
                    root, _, views = self.independent_fixture(Path(temp), layout)
                    (views / "coreui").mkdir()
                    source = views / "coreui/Bridge.kt"
                    source.write_text(sentinel + "\n")
                    status, output = self.run_guard(guard, root, args)
                    self.assertEqual(1, status, output)
                    self.assertIn(str(source), output)

    def test_explicit_library_is_required_even_when_app_sources_exist(self):
        for guard, _, args in GUARDS:
            for state in ("missing", "empty", "linked-root", "linked-source"):
                with self.subTest(guard=guard, state=state), tempfile.TemporaryDirectory() as temp:
                    base = Path(temp)
                    root, _, display = self.fixture(base, "workspace")
                    (display / "View.kt").write_text("val prepared = true\n")
                    module = base / "independent"
                    if state != "missing":
                        views = module / "src/main/kotlin/app/vauchi/ui"
                        views.mkdir(parents=True)
                        if state == "linked-source":
                            (views / "View.kt").symlink_to(display / "View.kt")
                        elif state == "linked-root":
                            linked = base / "linked"
                            linked.symlink_to(module, target_is_directory=True)
                            module = linked
                    env = dict(os.environ, VAUCHI_ANDROID_DISPLAY_ROOT=str(module))
                    status, output = self.run_guard(guard, root, args, env)
                    self.assertEqual(2, status, output)

    def test_valid_independent_sources_pass_without_hiding_in_place_sources(self):
        for guard, sentinel, args in GUARDS:
            with self.subTest(guard=guard), tempfile.TemporaryDirectory() as temp:
                root, _, views = self.independent_fixture(Path(temp), "workspace")
                (views / "View.kt").write_text("val prepared = true\n")
                status, output = self.run_guard(guard, root, args)
                self.assertEqual(0, status, output)
                source = root / "android/display/src/main/kotlin/app/vauchi/ui/View.kt"
                source.write_text(sentinel + "\n")
                status, output = self.run_guard(guard, root, args)
                self.assertEqual(1, status, output)
                self.assertIn(str(source), output)

    def test_explicit_library_sources_are_scanned_including_ignored_files(self):
        for guard, sentinel, args in GUARDS:
            with self.subTest(guard=guard), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                root, _, display = self.fixture(base, "workspace")
                (display / "View.kt").write_text("val prepared = true\n")
                _, module, views = self.independent_fixture(base, "standalone")
                moved = base / "custom display module"
                module.rename(moved)
                views = moved / views.relative_to(module)
                (views / ".ignore").write_text("Bridge.kt\n")
                source = views / "Bridge.kt"
                source.write_text(sentinel + "\n")
                env = dict(os.environ, VAUCHI_ANDROID_DISPLAY_ROOT=str(moved))
                status, output = self.run_guard(guard, root, args, env)
                self.assertEqual(1, status, output)
                self.assertIn(str(source), output)

    def test_unrelated_source_tree_preserves_the_non_android_no_op(self):
        for guard, _, args in GUARDS:
            with self.subTest(guard=guard), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / "src").mkdir()
                (root / "src/lib.rs").write_text("pub fn render() {}\n")
                status, output = self.run_guard(guard, root, args)
                self.assertEqual(0, status, output)

    def test_standalone_identity_requires_sources_after_deletion(self):
        for guard, _, args in GUARDS:
            for state in ("empty", "deleted-src"):
                with self.subTest(guard=guard, state=state), tempfile.TemporaryDirectory() as temp:
                    root, _, _ = self.independent_fixture(Path(temp), "standalone")
                    if state == "deleted-src":
                        shutil.rmtree(root / "src")
                    status, output = self.run_guard(guard, root, args)
                    self.assertEqual(2, status, output)


if __name__ == "__main__":
    unittest.main()
