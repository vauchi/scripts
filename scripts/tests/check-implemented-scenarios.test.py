#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Contract tests for check-implemented-scenarios.py: a scenario tagged
@implemented needs at least one test annotated with its name
(vauchi/private#268, owner decision 2026-10-10)."""

import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check-implemented-scenarios.py"

FEATURE = """\
Feature: Duress PIN

  @implemented
  Scenario: Enable duress mode
    Given a user

  @implemented @mobile
  Scenario Outline: Unlock with <pin>
    Given a user

  @planned
  Scenario: Plan only
    Given a user
"""


def _tree(root: Path, tests: dict[str, str], baseline: str | None = None) -> None:
    (root / "features").mkdir()
    (root / "features" / "duress_pin.feature").write_text(FEATURE)
    for rel, body in tests.items():
        path = root / "repo" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
    (root / "repo").mkdir(exist_ok=True)
    if baseline is not None:
        (root / "baseline").write_text(baseline)


def _run(root: Path, *extra: str) -> subprocess.CompletedProcess:
    args = [
        sys.executable,
        str(SCRIPT),
        "--features",
        str(root / "features"),
        "--baseline",
        str(root / "baseline"),
        *extra,
        str(root / "repo"),
    ]
    return subprocess.run(args, capture_output=True, text=True)


def test_every_implemented_scenario_with_a_test_passes() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(
            root,
            {
                "a.rs": "// @scenario: duress_pin :: Enable duress mode\n#[test]\nfn a() {}\n",
                "b.swift": "// @scenario: duress_pin.feature:Unlock with <pin>\nfunc testB() {}\n",
            },
            baseline="",
        )
        run = _run(root)
        assert run.returncode == 0, run.stdout + run.stderr
        assert "2 of 2 @implemented scenarios have a test" in run.stdout, run.stdout


def test_an_implemented_scenario_without_a_test_fails_and_is_named() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(root, {"a.rs": "// @scenario: duress_pin :: Enable duress mode\n"}, baseline="")
        run = _run(root)
        assert run.returncode == 1, run.stdout + run.stderr
        assert "duress_pin :: Unlock with <pin>" in run.stdout, run.stdout
        assert "Enable duress mode" not in run.stdout.split("no test")[-1], run.stdout


def test_a_baselined_scenario_without_a_test_passes() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(
            root,
            {"a.rs": "// @scenario: duress_pin :: Enable duress mode\n"},
            baseline="# grandfathered\nduress_pin :: Unlock with <pin>\n",
        )
        run = _run(root)
        assert run.returncode == 0, run.stdout + run.stderr


def test_matching_ignores_case_and_spacing_but_not_wording() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(
            root,
            {
                "a.kt": "// @scenario: duress_pin::  enable   DURESS mode\n",
                "b.cs": "// @scenario: duress_pin :: Unlock with a pin\n",
            },
            baseline="",
        )
        run = _run(root)
        assert run.returncode == 1, run.stdout + run.stderr
        assert "duress_pin :: Unlock with <pin>" in run.stdout, run.stdout
        assert "1 of 2 @implemented scenarios have a test" in run.stdout, run.stdout


def test_a_planned_scenario_needs_no_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(
            root,
            {
                "a.rs": "// @scenario: duress_pin :: Enable duress mode\n"
                "// @scenario: duress_pin :: Unlock with <pin>\n"
            },
            baseline="",
        )
        run = _run(root)
        assert run.returncode == 0, run.stdout + run.stderr
        assert "Plan only" not in run.stdout, run.stdout


def test_a_baseline_entry_that_now_has_a_test_is_reported_for_removal() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(
            root,
            {
                "a.rs": "// @scenario: duress_pin :: Enable duress mode\n"
                "// @scenario: duress_pin :: Unlock with <pin>\n"
            },
            baseline="duress_pin :: Unlock with <pin>\n",
        )
        run = _run(root)
        assert run.returncode == 0, run.stdout + run.stderr
        assert "remove from the baseline" in run.stdout, run.stdout
        assert "duress_pin :: Unlock with <pin>" in run.stdout, run.stdout
        strict = _run(root, "--strict")
        assert strict.returncode == 1, strict.stdout + strict.stderr


def test_write_baseline_lists_exactly_the_untested_scenarios() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(root, {"a.rs": "// @scenario: duress_pin :: Enable duress mode\n"})
        run = _run(root, "--write-baseline")
        assert run.returncode == 0, run.stdout + run.stderr
        entries = [
            line
            for line in (root / "baseline").read_text().splitlines()
            if line and not line.startswith("#")
        ]
        assert entries == ["duress_pin :: Unlock with <pin>"], entries
        assert _run(root).returncode == 0


# vauchi/private#620: annotations naming no scenario at all (a renamed or
# deleted scenario, or one nobody wrote) counted toward nothing and went
# unnoticed; 1,289 were on main. A second baseline lists them and may only
# shrink.
DANGLING_TESTS = {
    "a.rs": "// @scenario: duress_pin :: Enable duress mode\n"
            "// @scenario: duress_pin :: Unlock with <pin>\n"
            "// @scenario: duress_pin :: Enable duress mod\n",
}


def test_an_annotation_naming_no_scenario_fails_and_is_named() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(root, DANGLING_TESTS, baseline="")
        (root / "dangling").write_text("")
        run = _run(root, "--dangling-baseline", str(root / "dangling"))
        assert run.returncode == 1, run.stdout + run.stderr
        assert "1 @scenario annotation(s) naming no scenario" in run.stdout, run.stdout
        assert "duress_pin :: enable duress mod" in run.stdout, run.stdout


def test_a_baselined_dangling_annotation_passes() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(root, DANGLING_TESTS, baseline="")
        (root / "dangling").write_text("# grandfathered\nduress_pin :: Enable duress mod\n")
        run = _run(root, "--dangling-baseline", str(root / "dangling"))
        assert run.returncode == 0, run.stdout + run.stderr


def test_an_annotation_naming_a_planned_scenario_is_not_dangling() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(root, {**DANGLING_TESTS, "b.rs": "// @scenario: duress_pin :: Plan only\n"},
              baseline="")
        (root / "dangling").write_text("duress_pin :: Enable duress mod\n")
        run = _run(root, "--dangling-baseline", str(root / "dangling"))
        assert run.returncode == 0, run.stdout + run.stderr


def test_without_the_flag_dangling_annotations_are_not_checked() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(root, DANGLING_TESTS, baseline="")
        run = _run(root)
        assert run.returncode == 0, run.stdout + run.stderr


def test_write_baseline_also_writes_the_dangling_baseline() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(root, DANGLING_TESTS)
        run = _run(root, "--dangling-baseline", str(root / "dangling"), "--write-baseline")
        assert run.returncode == 0, run.stdout + run.stderr
        entries = [
            line
            for line in (root / "dangling").read_text().splitlines()
            if line and not line.startswith("#")
        ]
        assert entries == ["duress_pin :: enable duress mod"], entries
        assert _run(root, "--dangling-baseline", str(root / "dangling")).returncode == 0


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def _git_repo(root: Path, base: dict[str, str], added: dict[str, str]) -> str:
    """A repo whose first commit holds `base`; `added` lands in a second commit.
    Returns the first commit's sha, the merge-request diff base."""
    _tree(root, base)
    repo = root / "repo"
    _git(repo, "init", "-q")
    _git(repo, "config", "user.email", "t@example.invalid")
    _git(repo, "config", "user.name", "t")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "--allow-empty", "-m", "base")
    sha = _git(repo, "rev-parse", "HEAD")
    for rel, body in added.items():
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / rel).write_text(body)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "--allow-empty", "-m", "mr")
    return sha


def _run_added_since(root: Path, base: str) -> subprocess.CompletedProcess:
    args = [sys.executable, str(SCRIPT), "--features", str(root / "features"),
            "--added-since", base, str(root / "repo")]
    return subprocess.run(args, check=False, capture_output=True, text=True)


# The gate a core or relay MR runs (vauchi/private#994): an @scenario
# annotation the MR adds must name a scenario features main has.
def test_an_added_annotation_naming_a_scenario_passes_without_a_baseline() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        base = _git_repo(root, {}, {
            "a.rs": "// @scenario: duress_pin :: Enable duress mode\n#[test]\nfn a() {}\n",
            "b.rs": "// @scenario: duress_pin :: Plan only\n#[test]\nfn b() {}\n",
        })
        run = _run_added_since(root, base)
        assert run.returncode == 0, run.stdout + run.stderr
        assert "2 added @scenario annotation(s) name a scenario" in run.stdout, run.stdout


def test_an_added_annotation_naming_no_scenario_fails_and_is_named() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        base = _git_repo(root, {}, {
            "a.rs": "// @scenario: duress_pin :: Enable duress mode\n",
            "b.rs": "// @scenario: relay_exchange :: A code is claimed once\n",
        })
        run = _run_added_since(root, base)
        assert run.returncode == 1, run.stdout + run.stderr
        assert "1 added @scenario annotation(s) name no scenario" in run.stdout, run.stdout
        assert "relay_exchange :: a code is claimed once" in run.stdout, run.stdout
        assert "enable duress mode" not in run.stdout.split("no scenario")[-1], run.stdout


def test_a_dangling_annotation_the_mr_did_not_add_is_not_its_problem() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        base = _git_repo(
            root,
            {"old.rs": "// @scenario: duress_pin :: Enable duress mod\n"},
            {"new.rs": "// @internal\n#[test]\nfn n() {}\n"},
        )
        run = _run_added_since(root, base)
        assert run.returncode == 0, run.stdout + run.stderr
        assert "0 added @scenario annotation(s)" in run.stdout, run.stdout


def test_a_diff_base_git_does_not_know_is_an_error_not_a_pass() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _git_repo(root, {}, {"a.rs": "// @scenario: duress_pin :: Enable duress mode\n"})
        run = _run_added_since(root, "0" * 40)
        assert run.returncode == 2, run.stdout + run.stderr
        assert "git diff" in run.stderr, run.stderr


def test_no_feature_files_is_an_error_not_a_pass() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _tree(root, {}, baseline="")
        (root / "features" / "duress_pin.feature").unlink()
        run = _run(root)
        assert run.returncode == 2, run.stdout + run.stderr


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("check-implemented-scenarios.test: PASS")
