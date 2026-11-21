#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
"""cucumber-step-map.py tells a wired scenario whose every Then step is empty
from one that asserts, ranks empty steps by how many scenarios share them,
and exits non-zero while any step function is empty (vauchi/private#960)."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "cucumber-step-map.py"

STEPS = r'''
#[given("I have an identity")]
fn have_identity(world: &mut World) { world.identity = Some(1); }

#[when(expr = "I pick the {string} theme")]
fn pick_theme(world: &mut World, name: String) { world.theme = Some(name); }

#[then("the theme should be applied")]
fn theme_applied(_world: &mut World) {}

#[then(regex = r"^the contrast ratio is at least (\d+):1$")]
fn contrast_ok(world: &mut World, ratio: u32) { assert!(world.contrast >= ratio); }

#[then("nothing is sent")]
fn nothing_sent(_world: &mut World) {}
'''

FEATURES = """Feature: Theming
  @implemented
  Scenario: Pick a theme
    Given I have an identity
    When I pick the "Nord" theme
    Then the theme should be applied

  @implemented
  Scenario: Contrast holds
    Given I have an identity
    When I pick the "Nord" theme
    Then the contrast ratio is at least 4:1
    And nothing is sent

  @implemented
  Scenario: Unbound step
    Given I have an identity
    When I shake the phone
    Then nothing is sent

  @planned
  Scenario: Planned work
    Given I have an identity
    Then the theme should be applied

  @implemented
  Scenario Outline: Pick <name> by outline
    Given I have an identity
    When I pick the "<name>" theme
    Then the theme should be applied

    Examples:
      | name |
      | Nord |
"""

RUN = """Feature: Theming
  Scenario: Pick a theme
   ✔  Given I have an identity
   ✔  When I pick the "Nord" theme
   ✔  Then the theme should be applied
  Scenario: Contrast holds
   ✔  Given I have an identity
   ✔  When I pick the "Nord" theme
   ✔  Then the contrast ratio is at least 4:1
   ✔  And nothing is sent
  Scenario: Unbound step
   ✔  Given I have an identity
   ?  When I shake the phone
   ?  Then nothing is sent
  Scenario Outline: Pick Nord by outline
   ✔  Given I have an identity
   ✔  When I pick the "Nord" theme
   ✔  Then the theme should be applied
"""

TEST_FILE = """// @scenario: theming :: Pick a theme
#[test]
fn picking_a_theme_applies_it() { assert!(true); }
"""


class CucumberStepMapTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        (root / "steps").mkdir()
        (root / "steps" / "theming.rs").write_text(STEPS, encoding="utf-8")
        (root / "features").mkdir()
        (root / "features" / "theming.feature").write_text(FEATURES, encoding="utf-8")
        (root / "run.txt").write_text(RUN, encoding="utf-8")
        (root / "core").mkdir()
        (root / "core" / "theme_tests.rs").write_text(TEST_FILE, encoding="utf-8")
        self.root = root

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_tool(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True)

    def test_classify_tells_vacuous_from_asserting_and_skips_planned(self) -> None:
        result = self.run_tool("classify", "--steps", str(self.root / "steps"),
                               "--features", str(self.root / "features"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("scenarios considered: 4", result.stdout)
        self.assertIn("asserting: 1", result.stdout)
        self.assertIn("vacuous: 2", result.stdout, "a quoted outline placeholder still matches {string}")
        self.assertIn("unwired: 1", result.stdout)
        self.assertIn("VACUOUS: theming :: Pick a theme", result.stdout)

    def test_classify_with_a_run_counts_only_scenarios_the_runner_passed(self) -> None:
        result = self.run_tool("classify", "--steps", str(self.root / "steps"),
                               "--features", str(self.root / "features"), "--run", str(self.root / "run.txt"))
        self.assertIn("scenarios considered: 3", result.stdout)
        self.assertIn("vacuous: 2", result.stdout, "the outline row counts with its expanded step text")
        self.assertIn("unclassified: 0", result.stdout)

    def test_worklist_ranks_empty_steps_by_use_and_names_the_annotated_proof(self) -> None:
        result = self.run_tool("worklist", "--steps", str(self.root / "steps"),
                               "--features", str(self.root / "features"), "--tests", str(self.root / "core"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("empty step functions: 2 of 5", result.stdout)
        self.assertIn("  2 scenario(s)  theming.rs::theme_applied", result.stdout)
        self.assertIn("  2 scenario(s)  theming.rs::nothing_sent", result.stdout)
        self.assertNotIn("Planned work", result.stdout, "planned scenarios are not work for the step library")
        self.assertIn("theming :: Pick a theme  proof: " + str(self.root / "core" / "theme_tests.rs") + ":1", result.stdout)
        self.assertIn("theming :: Contrast holds  proof: none annotated", result.stdout)

    def test_empty_steps_exits_nonzero_while_any_step_is_empty(self) -> None:
        result = self.run_tool("empty-steps", "--steps", str(self.root / "steps"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("empty step functions: 2 of 5", result.stdout)
        (self.root / "steps" / "theming.rs").write_text(STEPS.replace("(_world: &mut World) {}", "(w: &mut World) { assert!(w.ok); }"), encoding="utf-8")
        result = self.run_tool("empty-steps", "--steps", str(self.root / "steps"))
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
