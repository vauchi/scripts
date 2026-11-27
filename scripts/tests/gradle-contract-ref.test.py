#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""The schema fetch must use one exact contract release from a real lock."""

from pathlib import Path
import random
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "gradle-contract-ref.py"


class GradleContractRef(unittest.TestCase):
    def read_ref(self, text=None, *, state="regular"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = root / "gradle.lockfile"
            if state == "directory":
                lock.mkdir()
            elif state != "missing":
                data = text.encode("utf-8") if isinstance(text, str) else text
                target = root / "external" if state == "linked" else lock
                target.write_bytes(data)
                if state == "linked":
                    lock.symlink_to(target)
            return subprocess.run(
                ["python3", str(SCRIPT), str(lock)], capture_output=True,
                text=True, check=False,
            )

    # @internal — #1358: generated native locks identify the schema release.
    def test_generated_versions_select_the_exact_contract_tag(self):
        generator = random.Random(1358)
        for _ in range(24):
            version = ".".join(str(generator.randrange(1000)) for _ in range(3))
            with self.subTest(version=version):
                result = self.read_ref(
                    "# Gradle generated lock\n"
                    "# app.vauchi:contract:9.9.9=unused\n"
                    "app.vauchi:contract-extra:8.8.8=debugRuntimeClasspath\n"
                    "app.vauchi:vauchi-platform:0.110.0=debugRuntimeClasspath\n"
                    f"app.vauchi:contract:{version}=debugCompileClasspath,releaseRuntimeClasspath\n"
                    "empty=androidJdkImage\n"
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"v{version}\n")
                self.assertEqual(result.stderr, "")

    # @internal — DC-01: missing, dynamic and conflicting pins never select main.
    def test_invalid_lock_inputs_fail_without_a_ref(self):
        invalid = [
            "", "# app.vauchi:contract:0.102.0=debugRuntimeClasspath\n",
            "app.vauchi:vauchi-platform:0.110.0=debugRuntimeClasspath\n",
            "app.vauchi:contract:0.102.0=\n",
            "app.vauchi:contract:0.102.0=debug,,release\n",
            "app.vauchi:contract:0.102.0=debug,debug\n",
            "app.vauchi:contract:0.102.0=debug runtime\n",
            "app.vauchi:contract:0.102.0=debug\x00\n",
            "app.vauchi:contract:0.102.0=debug;echo\n",
            "app.vauchi:contract:0.102.0=\u202erelease\n",
            "app.vauchi:contract:0.102.0=debug\napp.vauchi:contract:0.103.0=release\n",
            "app.vauchi:contract:0.102.0=debug\napp.vauchi:contract:0.102.0=release\n",
            b"app.vauchi:contract:0.102.0=debug\xff\n",
            "#" * (1024 * 1024 + 1),
        ]
        for version in ["+", "latest.release", "0.102.+", "[0.102,0.103)",
                        "v0.102.0", "0.102.0-SNAPSHOT", "0.102.0+meta",
                        "00.102.0", "0.102", "0.102.0;echo bad", "0.102.0\x00"]:
            invalid.append(f"app.vauchi:contract:{version}=debugRuntimeClasspath\n")
        for index, text in enumerate(invalid):
            with self.subTest(index=index):
                result = self.read_ref(text)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertIn("ERROR:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    # @internal — DC-03: absent or indirect lock inputs are not proof of a pin.
    def test_required_lock_must_be_a_regular_source_file(self):
        for state in ["missing", "directory", "linked"]:
            with self.subTest(state=state):
                result = self.read_ref("app.vauchi:contract:0.102.0=debug\n", state=state)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertIn("ERROR:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
