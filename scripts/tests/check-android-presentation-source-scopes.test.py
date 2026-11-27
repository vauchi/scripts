#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Independent presentation sources must supersede stale app/module copies."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
AUDITS = {
    "parser": ("check-component-parser-parity.py", "PresentationParser.kt", '"Text"\n"Divider"\n', '"Text"\n', "Divider"),
    "rows": ("check-presentation-row-field-coverage.py", "PresentationNodeRenderer.kt", "render(row.title, row.subtitle)\n", "render(row.title)\n", "subtitle"),
}
PRESENTATION = Path("src/main/kotlin/app/vauchi/ui/presentation")
SCHEMA = """pub enum PresentationNode {
    Text { value: String },
    Divider,
}
pub struct PresentationRow {
    pub title: String,
    pub subtitle: Option<String>,
}
"""


class AndroidPresentationSourceScopes(unittest.TestCase):
    def fixture(self, base, layout, audit):
        _, filename, complete, _, _ = AUDITS[audit]
        schema = base / "nodes.rs"
        schema.write_text(SCHEMA)
        exemptions = base / "exemptions.json"
        exemptions.write_text("{}")
        workspace = base / "workspace"
        for module in (workspace / "android/app", workspace / "android/display", workspace / "android-display"):
            (module / PRESENTATION).mkdir(parents=True)
            (module / PRESENTATION / filename).write_text(complete)
        (workspace / "android/settings.gradle.kts").write_text('include(":app", ":display")\n')
        independent = workspace / "android-display"
        (independent / "settings.gradle.kts").write_text('rootProject.name = "android-display"\n')
        root = independent if layout == "standalone" else workspace
        return root, independent, schema, exemptions

    def run_audit(self, audit, root, schema, exemptions, env=None):
        script = SCRIPTS / AUDITS[audit][0]
        args = ["--workspace", str(root), "--frontend", "android"]
        if audit == "parser":
            args += ["--protocol", "presentation", "--enum-file", str(schema)]
        else:
            args += ["--struct-file", str(schema), "--exemptions", str(exemptions)]
        result = subprocess.run(["python3", str(script), *args], capture_output=True, text=True, env=env, check=False)
        return result.returncode, result.stdout + result.stderr

    def test_independent_omissions_cannot_hide_behind_stale_copies(self):
        for layout in ("workspace", "standalone"):
            for audit, (_, filename, _, incomplete, missing) in AUDITS.items():
                with self.subTest(layout=layout, audit=audit), tempfile.TemporaryDirectory() as temp:
                    root, module, schema, exemptions = self.fixture(Path(temp), layout, audit)
                    status, output = self.run_audit(audit, root, schema, exemptions)
                    self.assertEqual(0, status, output)
                    (module / PRESENTATION / filename).write_text(incomplete)
                    status, output = self.run_audit(audit, root, schema, exemptions)
                    self.assertEqual(1, status, output)
                    self.assertIn(missing, output)

    def test_required_independent_input_cannot_be_missing_empty_or_linked(self):
        for audit, (_, filename, complete, _, _) in AUDITS.items():
            for state in ("deleted-file", "deleted-module", "empty-module", "linked-file", "linked-directory", "linked-module", "invalid-encoding"):
                with self.subTest(audit=audit, state=state), tempfile.TemporaryDirectory() as temp:
                    base = Path(temp)
                    root, module, schema, exemptions = self.fixture(base, "workspace", audit)
                    source = module / PRESENTATION / filename
                    if state == "deleted-file":
                        source.unlink()
                    elif state == "deleted-module":
                        shutil.rmtree(module)
                    elif state == "empty-module":
                        shutil.rmtree(module / "src")
                    elif state == "linked-file":
                        peer = base / filename
                        peer.write_text(complete)
                        source.unlink()
                        source.symlink_to(peer)
                    elif state == "linked-directory":
                        peer = base / "sources"
                        source.parent.rename(peer)
                        source.parent.symlink_to(peer, target_is_directory=True)
                    elif state == "linked-module":
                        linked = base / "linked-module"
                        linked.symlink_to(module, target_is_directory=True)
                        module = linked
                    else:
                        source.write_bytes(complete.encode() + b"\xff")
                    env = dict(os.environ, VAUCHI_ANDROID_DISPLAY_ROOT=str(module))
                    status, output = self.run_audit(audit, root, schema, exemptions, env)
                    self.assertEqual(2, status, output)

    def test_custom_module_paths_and_empty_declarations(self):
        for audit in AUDITS:
            for state in ("valid", "empty"):
                with self.subTest(audit=audit, state=state), tempfile.TemporaryDirectory() as temp:
                    base = Path(temp)
                    root, module, schema, exemptions = self.fixture(base, "workspace", audit)
                    moved = base / "custom display"
                    module.rename(moved)
                    env = dict(os.environ, VAUCHI_ANDROID_DISPLAY_ROOT=str(moved) if state == "valid" else "")
                    status, output = self.run_audit(audit, root, schema, exemptions, env)
                    self.assertEqual(0 if state == "valid" else 2, status, output)

    def test_standalone_identity_still_requires_deleted_sources(self):
        for audit in AUDITS:
            with self.subTest(audit=audit), tempfile.TemporaryDirectory() as temp:
                root, module, schema, exemptions = self.fixture(Path(temp), "standalone", audit)
                shutil.rmtree(module / "src")
                status, output = self.run_audit(audit, root, schema, exemptions)
                self.assertEqual(2, status, output)

    def test_component_protocol_still_audits_the_app(self):
        with tempfile.TemporaryDirectory() as temp:
            root, _, _, _ = self.fixture(Path(temp), "workspace", "parser")
            schema = Path(temp) / "component.rs"
            schema.write_text("pub enum Component {\n    Text,\n    Divider,\n}\n")
            source = root / "android/app/src/main/kotlin/app/vauchi/ui/coreui/Models.kt"
            source.parent.mkdir()
            source.write_text('"Text" -> render()\n"Divider" -> render()\n')
            result = subprocess.run(["python3", str(SCRIPTS / AUDITS["parser"][0]), "--workspace", str(root), "--frontend", "android", "--enum-file", str(schema)], capture_output=True, text=True, check=False)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_empty_schema_cannot_disable_row_coverage(self):
        with tempfile.TemporaryDirectory() as temp:
            root, _, schema, exemptions = self.fixture(Path(temp), "workspace", "rows")
            schema.write_text("pub struct PresentationRow {\n}\n")
            status, output = self.run_audit("rows", root, schema, exemptions)
            self.assertEqual(2, status, output)
            self.assertIn("no PresentationRow fields", output)

    def test_linked_standalone_checkout_is_rejected(self):
        for audit in AUDITS:
            with self.subTest(audit=audit), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                _, module, schema, exemptions = self.fixture(base, "standalone", audit)
                linked = base / "linked-checkout"
                linked.symlink_to(module, target_is_directory=True)
                status, output = self.run_audit(audit, linked, schema, exemptions)
                self.assertEqual(2, status, output)

    def test_row_directory_ignores_assets_but_rejects_corrupt_code(self):
        with tempfile.TemporaryDirectory() as temp:
            root, _, schema, exemptions = self.fixture(Path(temp), "workspace", "rows")
            directory = root / "windows-display/src/Vauchi.Display"
            directory.mkdir(parents=True)
            renderer = directory / "Collections.cs"
            renderer.write_text("render(row.Title, row.Subtitle);\n")
            (directory / "icon.png").write_bytes(b"\x89PNG\xff.title.subtitle")
            args = ["python3", str(SCRIPTS / AUDITS["rows"][0]), "--workspace", str(root), "--frontend", "windows", "--struct-file", str(schema), "--exemptions", str(exemptions)]
            result = subprocess.run(args, capture_output=True, text=True, check=False)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            renderer.write_text("render(row.Title);\n")
            result = subprocess.run(args, capture_output=True, text=True, check=False)
            self.assertEqual(1, result.returncode, result.stdout + result.stderr)
            self.assertIn("subtitle", result.stdout + result.stderr)
            renderer.write_text("render(row.Title, row.Subtitle);\n")
            (directory / "Broken.cs").write_bytes(b"// invalid UTF-8\xff")
            result = subprocess.run(args, capture_output=True, text=True, check=False)
            self.assertEqual(2, result.returncode, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
