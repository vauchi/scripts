#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
"""repo-registry.py answers the queries the workspace's lists used to hold by
hand, and `check` names every place that fell out of step (private#1013).
Observed red before `ops`, `scenario-roots` and `check` existed: unknown
command, exit 2."""
from __future__ import annotations

import os
import subprocess
import sys
import shutil
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "lib" / "repo-registry.py"

REGISTRY = """
[[repo]]
name = "core"
path = "core"
ecosystem = "rust"
public = true
ops = ["build", "test", "fmt"]
scenario_root = true
profile = true

[[repo]]
name = "docs"
path = "docs"
ecosystem = "mdbook"
public = true
ops = ["build"]
scenario_root = false
profile = true

[[repo]]
name = "private"
path = "_private"
ecosystem = "none"
private = true
ops = []
scenario_root = false
profile = false
"""


def run(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(HELPER), *args], cwd=cwd, capture_output=True, text=True, check=False
    )


class RepoRegistryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        (self.root / "repos.toml").write_text(REGISTRY, encoding="utf-8")
        (self.root / ".gitignore").write_text("/core/\n/docs/\n/_private/\n", encoding="utf-8")
        (self.root / "README.md").write_text(
            "| Repo | What |\n|---|---|\n| [core/](core/) | Core |\n| [docs/](docs/) | Docs |\n",
            encoding="utf-8",
        )
        (self.root / "gitlab-profile").mkdir()
        (self.root / "gitlab-profile" / "README.md").write_text(
            "| [core](https://gitlab.com/vauchi/core) | Core | badge |\n"
            "| [docs](https://gitlab.com/vauchi/docs) | Docs | badge |\n",
            encoding="utf-8",
        )

    def test_ops_lists_the_repos_a_recipe_accepts(self) -> None:
        self.assertEqual(run(self.root, "ops", "build").stdout.split(), ["core", "docs"])
        self.assertEqual(run(self.root, "ops", "fmt").stdout.split(), ["core"])
        self.assertEqual(run(self.root, "ops", "bench").stdout.split(), [])

    def test_scenario_roots_are_the_repos_whose_tests_carry_annotations(self) -> None:
        self.assertEqual(run(self.root, "scenario-roots").stdout.split(), ["core"])

    def test_check_passes_when_every_list_matches(self) -> None:
        result = run(self.root, "check", str(self.root))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("0 registry mismatch(es)", result.stdout)

    def test_check_names_each_list_that_lacks_a_repository(self) -> None:
        (self.root / ".gitignore").write_text("/core/\n/_private/\n", encoding="utf-8")
        (self.root / "README.md").write_text("| [core/](core/) | Core |\n", encoding="utf-8")
        (self.root / "gitlab-profile" / "README.md").write_text(
            "| [core](https://gitlab.com/vauchi/core) | Core |\n", encoding="utf-8"
        )
        result = run(self.root, "check", str(self.root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("REGISTRY: .gitignore lacks /docs/ (docs)", result.stdout)
        self.assertIn("REGISTRY: README.md table lacks a row for docs", result.stdout)
        self.assertIn("REGISTRY: gitlab-profile/README.md lacks a row for docs", result.stdout)
        self.assertIn("3 registry mismatch(es)", result.stdout)

    def test_check_skips_the_group_readme_when_gitlab_profile_is_not_cloned(self) -> None:
        shutil.rmtree(self.root / "gitlab-profile")
        result = run(self.root, "check", str(self.root))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("gitlab-profile/README.md lacks", result.stdout)
        self.assertIn("gitlab-profile/README.md not cloned; group README unchecked", result.stdout)

    def test_private_and_tooling_repos_need_no_readme_row(self) -> None:
        result = run(self.root, "check", str(self.root))
        self.assertNotIn("private", result.stdout.replace("0 registry", ""))


if __name__ == "__main__":
    unittest.main()
