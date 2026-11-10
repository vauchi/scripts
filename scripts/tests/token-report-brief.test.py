#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""The one-line cost verdict session-end prints (vauchi/private#1198)."""
import importlib.util
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "token_report", SCRIPT_DIR / "token-report.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def week(eff, commits):
    return dict(eff=eff, out=0, msgs=0, sub=0.0, com=commits, lin=0)


class CostPerCommitVerdictTests(unittest.TestCase):
    def test_compares_the_last_two_full_weeks_with_the_two_before(self):
        wk = {
            "2026-W41": week(400e6, 1000),
            "2026-W42": week(600e6, 1000),
            "2026-W43": week(300e6, 1000),
            "2026-W44": week(200e6, 1000),
            "2026-W45": week(900e6, 10),
        }
        verdict = MODULE.cost_per_commit_verdict(wk, this_week="2026-W45")
        self.assertEqual(verdict["recent"], ["2026-W43", "2026-W44"])
        self.assertEqual(verdict["prior"], ["2026-W41", "2026-W42"])
        self.assertEqual(verdict["recent_k"], 250.0)
        self.assertEqual(verdict["prior_k"], 500.0)
        self.assertEqual(verdict["delta_pct"], -50.0)

    def test_skips_weeks_without_both_spend_and_commits(self):
        wk = {
            "2026-W40": week(100e6, 100),
            "2026-W41": week(0, 100),
            "2026-W42": week(100e6, 0),
            "2026-W43": week(200e6, 100),
            "2026-W44": week(300e6, 100),
            "2026-W45": week(400e6, 100),
        }
        verdict = MODULE.cost_per_commit_verdict(wk, this_week="2026-W46")
        self.assertEqual(verdict["recent"], ["2026-W44", "2026-W45"])
        self.assertEqual(verdict["prior"], ["2026-W40", "2026-W43"])

    def test_needs_four_comparable_weeks(self):
        wk = {"2026-W43": week(1e6, 1), "2026-W44": week(1e6, 1),
              "2026-W45": week(1e6, 1)}
        self.assertIsNone(
            MODULE.cost_per_commit_verdict(wk, this_week="2026-W46"))


class BriefLineTests(unittest.TestCase):
    def test_one_line_names_both_windows_and_the_change(self):
        line = MODULE.brief_line({
            "recent": ["2026-W43", "2026-W44"], "prior": ["2026-W41", "2026-W42"],
            "recent_k": 278.4, "prior_k": 465.0, "delta_pct": -40.1})
        self.assertEqual(
            line,
            "  cost per commit (k-units): 278 last 2 wk (W43-W44) vs 465 "
            "prior (W41-W42), -40%")

    def test_worse_than_fifteen_percent_is_flagged(self):
        line = MODULE.brief_line({
            "recent": ["2026-W45", "2026-W46"], "prior": ["2026-W43", "2026-W44"],
            "recent_k": 600.0, "prior_k": 400.0, "delta_pct": 50.0})
        self.assertTrue(line.endswith("+50% WORSE"), line)

    def test_without_four_weeks_says_so(self):
        self.assertEqual(
            MODULE.brief_line(None),
            "  cost per commit (k-units): n/a (fewer than 4 comparable weeks)")


if __name__ == "__main__":
    unittest.main()
