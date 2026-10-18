#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Seeded-violation tests for check-ci-needs-rules.py (VCI06, private#490).

The first case is the ios!699 shape: a job hard-needs another whose
merge-request `changes:` are narrower, so a diff the needed job skips
makes GitLab reject the whole pipeline with zero jobs."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "check-ci-needs-rules.py"
SPEC = importlib.util.spec_from_file_location("check_ci_needs_rules", MODULE_PATH)
assert SPEC and SPEC.loader
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

MR = 'if: $CI_PIPELINE_SOURCE == "merge_request_event"'

IOS_699 = f"""
build:debug:
  script: [build]
  rules:
    - {MR}
      changes: ["**/*.swift", project.yml]
screenshots:store:
  script: [shoot]
  needs: [build:debug]
  rules:
    - {MR}
"""

NEEDING_WITHIN_NEEDED = f"""
build:debug:
  script: [build]
  rules:
    - {MR}
      changes: ["**/*.swift", project.yml]
screenshots:store:
  script: [shoot]
  needs: [build:debug]
  rules:
    - {MR}
      changes: ["Sources/**/*.swift"]
"""

OPTIONAL_NEED = f"""
build:debug:
  script: [build]
  rules:
    - {MR}
      changes: ["**/*.swift"]
screenshots:store:
  script: [shoot]
  needs: [{{job: build:debug, optional: true}}]
  rules:
    - {MR}
"""

EXTRA_PATH_VIA_EXTENDS_AND_REFERENCE = f"""
.swift-changes:
  rules:
    - {MR}
      changes:
        paths: ["**/*.swift", project.yml]
.catalog:
  rules:
    - if: $CI_PIPELINE_SOURCE == "api"
      when: never
    - {MR}
      changes:
        paths: ["**/*.swift", scripts/fetch-screen-catalog.sh]
build:debug:
  extends: .swift-changes
  script: [build]
test:screen-catalog:
  script: [catalog]
  needs: [{{job: build:debug, artifacts: true}}]
  rules:
    - !reference [.catalog, rules]
"""

NEVER_FIRST = f"""
build:debug:
  script: [build]
  rules:
    - {MR}
      changes: ["**/*.swift"]
docs:only:
  script: [docs]
  needs: [build:debug]
  rules:
    - {MR}
      when: never
"""


def violations(config: str) -> list[str]:
    with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as handle:
        handle.write(config)
    try:
        return CHECK.check(CHECK.load(Path(handle.name)), "ci.yml")
    finally:
        Path(handle.name).unlink()


class NeedsRulesTest(unittest.TestCase):
    def test_the_ios_699_shape_is_flagged(self):
        found = violations(IOS_699)
        self.assertEqual(len(found), 1, found)
        self.assertIn('VCI06: job "screenshots:store" needs "build:debug"', found[0])
        self.assertIn("an-unrelated-file.txt", found[0])

    def test_a_needing_job_within_the_needed_jobs_changes_passes(self):
        self.assertEqual(violations(NEEDING_WITHIN_NEEDED), [])

    def test_an_optional_need_passes(self):
        self.assertEqual(violations(OPTIONAL_NEED), [])

    def test_extends_and_reference_rules_are_resolved(self):
        found = violations(EXTRA_PATH_VIA_EXTENDS_AND_REFERENCE)
        self.assertEqual(len(found), 1, found)
        self.assertIn("scripts/fetch-screen-catalog.sh", found[0])

    def test_a_job_that_never_runs_on_merge_requests_passes(self):
        self.assertEqual(violations(NEVER_FIRST), [])

    def test_double_star_matches_any_depth_including_none(self):
        pattern = CHECK.glob_regex("**/*.swift")
        self.assertTrue(pattern.match("App.swift"))
        self.assertTrue(pattern.match("Sources/Views/App.swift"))
        self.assertFalse(pattern.match("App.swift.orig"))


if __name__ == "__main__":
    unittest.main()
