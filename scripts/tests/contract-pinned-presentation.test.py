#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Execute both presentation CI jobs against a contract-only consumer."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CONTRACT_REPO = "https://gitlab.com/vauchi/contract.git"
CORE_REPO = "https://gitlab.com/vauchi/core.git"


def job_script(template, job):
    lines = (ROOT / "ci-templates" / template).read_text(encoding="utf-8").splitlines()
    start = lines.index(job + ":")
    for index in range(start + 1, len(lines)):
        if lines[index] == "  script:":
            body = []
            for line in lines[index + 2 :]:
                if line and not line.startswith("      "):
                    break
                body.append(line[6:])
            return "\n".join(body)
    raise AssertionError(f"No script for {job}")


class ContractPinnedPresentation(unittest.TestCase):
    jobs = (
        ("parser-parity.yml", ".parser-parity-job"),
        ("design-drift.yml", ".design-drift-job"),
    )

    def run_job(self, template, job, *, missing=False, tagged=True, legacy=False, nodes=True,
                ref_file=None, kind="", gradle_lock=None, reader_fetch_fails=False):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            binary_dir = work / "bin"
            binary_dir.mkdir()
            (work / "Cargo.toml").write_text(
                '[dependencies]\nvauchi-contract = { git = "'
                + CONTRACT_REPO
                + ('", tag = "v0.97.2" }\n' if tagged else '", branch = "main" }\n')
            , encoding="utf-8")
            if ref_file is not None:
                (work / "contract-ref").write_text(ref_file, encoding="utf-8")
            if gradle_lock is not None:
                (work / "gradle.lockfile").write_text(gradle_lock, encoding="utf-8")
            (work / "nodes.rs").write_text(
                "pub enum PresentationNode {\n    Text { value: String },\n    Divider,\n}\n"
            , encoding="utf-8")
            (work / "renderer.rs").write_text(
                "PresentationNode::Text\n"
                + ("" if missing else "PresentationNode::Divider\n")
            , encoding="utf-8")
            fake_git = binary_dir / "git"
            fake_git.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, shutil, sys\n"
                "with open(os.environ['GIT_CALLS'], 'a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "if 'checkout' in sys.argv and os.environ['OMIT_NODES'] != '1':\n"
                "    target = pathlib.Path(sys.argv[sys.argv.index('-C') + 1])\n"
                "    for relative in ('src/presentation/surface/nodes.rs',\n"
                "                     'vauchi-core/src/platform/presentation/surface/nodes.rs'):\n"
                "        dest = target / relative\n"
                "        dest.parent.mkdir(parents=True, exist_ok=True)\n"
                "        shutil.copyfile(os.environ['FIXTURE_NODES'], dest)\n"
            , encoding="utf-8")
            fake_git.chmod(0o755)
            fake_fetch = (
                "#!/usr/bin/env python3\n"
                "import os, shutil, sys\n"
                "url = next(arg for arg in sys.argv if arg.startswith('https://'))\n"
                "reader = url.endswith('/gradle-contract-ref.py')\n"
                "if reader and os.environ['READER_FETCH_FAILS'] == '1': sys.exit(8)\n"
                "if reader and '/raw/test-ref/' not in url: sys.exit(9)\n"
                "option = '-O' if '-O' in sys.argv else '-o'\n"
                "source = 'CONTRACT_READER' if reader else 'PARSER_CHECKER'\n"
                "shutil.copyfile(os.environ[source], sys.argv[sys.argv.index(option) + 1])\n"
            )
            for fetcher in ("wget", "curl"):
                executable = binary_dir / fetcher
                executable.write_text(fake_fetch, encoding="utf-8")
                executable.chmod(0o755)
            env = {
                **os.environ,
                "PATH": str(binary_dir) + os.pathsep + os.environ["PATH"],
                "GIT_CALLS": str(work / "git.jsonl"),
                "FIXTURE_NODES": str(work / "nodes.rs"),
                "OMIT_NODES": "0" if nodes else "1",
                "PARSER_CHECKER": str(ROOT / "scripts/check-component-parser-parity.py"),
                "CONTRACT_READER": str(ROOT / "scripts/gradle-contract-ref.py"),
                "READER_FETCH_FAILS": "1" if reader_fetch_fails else "0",
                "FRONTEND_NAME": "linux-gtk",
                "PARSER_FILE": "renderer.rs",
                "PARSER_PROTOCOL": "presentation",
                "PARSER_SCRIPT_REF": "test-ref",
                "CORE_REF": "v0.99.1",
                "CORE_PIN_FILE": "",
                "CORE_PIN_KIND": "",
                "CORE_PINS_SCRIPT_REF": "test-ref",
                "CONTRACT_PIN_FILE": (
                    "" if legacy else "gradle.lockfile" if gradle_lock is not None
                    else "contract-ref" if ref_file is not None else "Cargo.toml"
                ),
                "CONTRACT_PIN_KIND": kind,
                "CI_PROJECT_NAME": "linux-gtk",
                "DESIGN_DRIFT_PROTOCOL": "presentation",
                "DESIGN_DRIFT_MATCH_MODE": "grep",
                "DESIGN_DRIFT_GREP_FILE": "renderer.rs",
            }
            # The metrics service is outside the presentation-check contract.
            script = "fetch_vauchi_script() { return 1; }\n" + job_script(template, job)
            result = subprocess.run(
                [os.environ.get("PRESENTATION_TEST_SHELL", "bash"), "-c", script], cwd=work, env=env,
                capture_output=True, text=True, check=False,
            )
            calls = work / "git.jsonl"
            git_calls = [json.loads(line) for line in calls.read_text(encoding="utf-8").splitlines()] if calls.exists() else []
            return result, git_calls

    # @internal — ADR-078 display checks read their own contract pin.
    def test_contract_only_consumer_uses_its_tag_without_fetching_core(self):
        for template, job in self.jobs:
            with self.subTest(job=job):
                result, calls = self.run_job(template, job)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(any(CONTRACT_REPO in call for call in calls), calls)
                self.assertFalse(any(CORE_REPO in call for call in calls), calls)
                self.assertTrue(any("refs/tags/v0.97.2" in call for call in calls), calls)

    # @internal — both gates must still reject an unrendered variant.
    def test_missing_contract_variant_is_rejected(self):
        for template, job in self.jobs:
            with self.subTest(job=job):
                result, _ = self.run_job(template, job, missing=True)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("Divider", result.stdout + result.stderr)

    # @internal — a missing release pin cannot silently select main.
    def test_contract_without_a_tag_is_rejected_before_fetch(self):
        for template, job in self.jobs:
            with self.subTest(job=job):
                result, calls = self.run_job(template, job, tagged=False)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("no vauchi-contract tag", result.stdout + result.stderr)
                self.assertEqual(calls, [])

    # @internal — an absent enum cannot report complete renderer coverage.
    def test_missing_enum_file_is_rejected(self):
        for template, job in self.jobs:
            with self.subTest(job=job):
                result, _ = self.run_job(template, job, nodes=False)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("missing", (result.stdout + result.stderr).lower())

    # @internal — a display shell with no Cargo manifest pins contract in a ref file.
    def test_a_ref_file_names_the_contract_tag(self):
        pin = "# The contract release this display renders.\n\nv0.98.0\n"
        for template, job in self.jobs:
            with self.subTest(job=job):
                result, calls = self.run_job(template, job, ref_file=pin, kind="ref-file")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(any("refs/tags/v0.98.0" in call for call in calls), calls)
                self.assertFalse(any(CORE_REPO in call for call in calls), calls)

    # @internal — an empty ref file cannot silently select main.
    def test_an_empty_ref_file_is_rejected_before_fetch(self):
        for template, job in self.jobs:
            with self.subTest(job=job):
                result, calls = self.run_job(template, job, ref_file="# none\n\n", kind="ref-file")
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("names no contract tag", result.stdout + result.stderr)
                self.assertEqual(calls, [])

    # @internal — a misspelt pin kind fails instead of falling back to Cargo.
    def test_an_unknown_pin_kind_is_rejected_before_fetch(self):
        for template, job in self.jobs:
            with self.subTest(job=job):
                result, calls = self.run_job(template, job, ref_file="v0.98.0\n", kind="ref")
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("CONTRACT_PIN_KIND", result.stdout + result.stderr)
                self.assertEqual(calls, [])

    # @internal — existing Core-pinned consumers keep their behavior.
    def test_legacy_core_reference_remains_supported(self):
        for template, job in self.jobs:
            with self.subTest(job=job):
                result, calls = self.run_job(template, job, legacy=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(any(CORE_REPO in call for call in calls), calls)

    # @internal — #1358: Android presentation checks use the exact locked SDK.
    def test_gradle_lock_selects_contract_and_still_detects_missing_variants(self):
        lock = "app.vauchi:contract:0.102.0=debugCompileClasspath,releaseRuntimeClasspath\n"
        for template, job in self.jobs:
            for missing in (False, True):
                with self.subTest(job=job, missing=missing):
                    result, calls = self.run_job(
                        template, job, kind="gradle-lock", gradle_lock=lock, missing=missing,
                    )
                    self.assertEqual(result.returncode, 1 if missing else 0, result.stdout + result.stderr)
                    self.assertTrue(any("refs/tags/v0.102.0" in call for call in calls), calls)
                    self.assertFalse(any(CORE_REPO in call for call in calls), calls)
                    if missing:
                        self.assertIn("Divider", result.stdout + result.stderr)

    # @internal — DC-01: unusable lock provenance must fail before any schema fetch.
    def test_invalid_gradle_lock_does_not_fall_back_to_core(self):
        for lock in ("", "# no contract\n", "app.vauchi:contract:+=debug\n",
                     "app.vauchi:contract:0.102.0=debug\napp.vauchi:contract:0.103.0=release\n"):
            for template, job in self.jobs:
                with self.subTest(job=job, lock=lock):
                    result, calls = self.run_job(template, job, kind="gradle-lock", gradle_lock=lock)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertIn("ERROR:", result.stdout + result.stderr)
                    self.assertEqual(calls, [])

    # @internal — CC-27: a failed pin-reader download cannot report parity success.
    def test_failed_lock_reader_download_stops_before_schema_fetch(self):
        lock = "app.vauchi:contract:0.102.0=debugCompileClasspath\n"
        for template, job in self.jobs:
            with self.subTest(job=job):
                result, calls = self.run_job(
                    template, job, kind="gradle-lock", gradle_lock=lock, reader_fetch_fails=True,
                )
                self.assertEqual(result.returncode, 8, result.stdout + result.stderr)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
