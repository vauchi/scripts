#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Contract tests for check-github-mirrors.py: every public gitlab.com/vauchi
project has a github.com/vauchi mirror whose main matches, and a check that
could not ask either side never reports clean (vauchi/private#1319)."""

import contextlib
import importlib.util
import io
from datetime import datetime, timezone
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "check-github-mirrors.py"
SPEC = importlib.util.spec_from_file_location("check_github_mirrors", MODULE_PATH)
assert SPEC and SPEC.loader
MIRRORS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MIRRORS)


class FakeSources:
    """GitLab and GitHub as plain data; `fail` names a method that raises."""

    def __init__(self, gitlab, github, fail=None):
        self.gitlab = gitlab  # path -> (sha, title, authored[, committed])
        self.github = github  # name -> (sha, title, authored)
        self.fail = fail
        self.asked = []

    def _maybe_fail(self, name):
        self.asked.append(name)
        if self.fail == name:
            raise MIRRORS.SourceError(f"{name}: HTTP 503")

    def public_projects(self):
        self._maybe_fail("public_projects")
        return sorted(self.gitlab)

    def github_repos(self):
        self._maybe_fail("github_repos")
        return set(self.github)

    def gitlab_head(self, path):
        self._maybe_fail("gitlab_head")
        return self.gitlab[path][0]

    def github_head(self, name):
        self._maybe_fail("github_head")
        return self.github[name][0]

    def gitlab_commit(self, path, sha):
        self._maybe_fail("gitlab_commit")
        _, title, authored, *committed = self.gitlab[path]
        return title, authored, (committed or [authored])[0]

    def github_commit(self, name, sha):
        self._maybe_fail("github_commit")
        _, title, authored = self.github[name]
        return title, authored


def run(sources):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = MIRRORS.main([], sources=sources, now=NOW)
    return code, out.getvalue()


def states(sources):
    return {f.repo: f.state for f in MIRRORS.check(sources, now=NOW)}


NOW = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)
COMMIT = ("a" * 40, "feat: x", "2026-11-17T23:14:11+01:00")
# Committed nine hours before NOW: past the grace a mirror push gets.
NEWER = ("b" * 40, "feat: y", "2026-11-20T03:00:00+00:00")
# Committed one hour before NOW: its main pipeline may still be pushing.
FRESH = ("d" * 40, "feat: z", "2026-11-19T08:00:00+00:00", "2026-11-20T11:00:00+00:00")


def test_a_mirror_at_gitlabs_main_is_in_sync():
    sources = FakeSources({"core": COMMIT}, {"core": COMMIT})
    assert states(sources) == {"core": "ok"}
    code, out = run(sources)
    assert code == 0
    assert "1 of 1 mirrors in sync" in out


def test_a_public_project_without_a_github_repo_is_missing():
    sources = FakeSources({"core": COMMIT, "spec": COMMIT}, {"core": COMMIT})
    assert states(sources) == {"core": "ok", "spec": "missing"}
    code, out = run(sources)
    assert code == 1
    assert "MISSING spec -> github.com/vauchi/spec" in out


def test_a_mirror_behind_main_past_the_grace_period_is_stale():
    sources = FakeSources({"core": NEWER}, {"core": COMMIT})
    assert states(sources) == {"core": "stale"}
    code, out = run(sources)
    assert code == 1
    assert "STALE core -> github.com/vauchi/core" in out


def test_a_mirror_behind_a_main_committed_within_the_grace_is_pending_not_stale():
    sources = FakeSources({"core": FRESH}, {"core": COMMIT})
    assert states(sources) == {"core": "pending"}
    code, _ = run(sources)
    assert code == 0


def test_a_history_rewritten_into_lfs_matches_by_subject_and_author_date():
    rewritten = ("c" * 40, "feat: x", "2026-11-17T22:14:11Z")
    sources = FakeSources({"ios": COMMIT}, {"ios": rewritten})
    assert states(sources) == {"ios": "ok"}


def test_a_different_subject_on_another_sha_is_stale():
    other = ("c" * 40, "feat: older", "2026-11-17T22:14:11Z")
    sources = FakeSources({"ios": COMMIT}, {"ios": other})
    assert states(sources) == {"ios": "stale"}


def test_the_same_subject_at_another_author_date_is_stale():
    other = ("c" * 40, "feat: x", "2026-11-16T22:14:11Z")
    sources = FakeSources({"ios": COMMIT}, {"ios": other})
    assert states(sources) == {"ios": "stale"}


def test_gitlab_profile_has_no_mirror_and_is_not_checked():
    sources = FakeSources({"gitlab-profile": COMMIT, "core": COMMIT}, {"core": COMMIT})
    assert states(sources) == {"core": "ok"}


def test_names_follow_the_mirror_jobs_github_names():
    sources = FakeSources(
        {"github-profile": COMMIT, "vauchi-platform-swift": COMMIT, "utils/rqrr": COMMIT},
        {".github": COMMIT, "vauchi-mobile-swift": COMMIT, "rqrr": COMMIT},
    )
    findings = {f.repo: (f.github, f.state) for f in MIRRORS.check(sources)}
    assert findings == {
        "github-profile": (".github", "ok"),
        "vauchi-platform-swift": ("vauchi-mobile-swift", "ok"),
        "utils/rqrr": ("rqrr", "ok"),
    }


def test_an_unreachable_source_fails_the_check_instead_of_reporting_clean():
    for method in ("public_projects", "github_repos", "gitlab_head", "github_head",
                   "gitlab_commit", "github_commit"):
        sources = FakeSources({"core": NEWER}, {"core": COMMIT}, fail=method)
        code, out = run(sources)
        assert method in sources.asked, method
        assert code == 2, method
        assert "could not check" in out, method
        assert "in sync" not in out, method


def test_no_public_projects_is_a_failure_not_an_empty_success():
    code, out = run(FakeSources({}, {}))
    assert code == 2
    assert "no public projects" in out


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for test in tests:
        try:
            test()
        except Exception as error:  # noqa: BLE001 — report every failing case
            failed += 1
            print(f"FAIL: {test.__name__}: {error!r}")
    print(f"check-github-mirrors.test: {len(tests) - failed} passed, {failed} failed")
    raise SystemExit(1 if failed else 0)
