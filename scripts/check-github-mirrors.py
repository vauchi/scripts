#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Check that every public gitlab.com/vauchi project has a github.com/vauchi
mirror whose main matches GitLab's (vauchi/private#1319).

The mirror job (ci-templates/github-mirror.yml) is allow_failure, so a
missing GitHub repo or a failing push stays silent; this check is what
notices. Exit 0: every mirror in sync, or behind a main committed within
the grace period. Exit 1: a mirror is missing or stale. Exit 2: GitLab or GitHub
could not be asked, which is never reported as clean.

Usage: check-github-mirrors.py
GITHUB_TOKEN, when set, raises GitHub's API rate limit; it is not required.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

GROUP = "vauchi"
GITLAB_API = "https://gitlab.com/api/v4"
GITHUB_API = "https://api.github.com"

# Maintainer decision 2026-11-20 (private#1314): the GitLab profile README
# has no GitHub counterpart.
NOT_MIRRORED = {"gitlab-profile"}
# github-profile pushes through a GitLab push mirror to GitHub's profile repo;
# vauchi-platform-swift's job sets GITHUB_MIRROR_REPO.
GITHUB_NAMES = {"github-profile": ".github", "vauchi-platform-swift": "vauchi-mobile-swift"}
# Merges are fast-forward only after a rebase on main (private#1179), so
# main's committer date is close to its merge; the mirror job pushes within
# minutes of the merge, long inside this. GitLab's pipeline API would say
# exactly, but answers 403 without a token for some public projects.
GRACE = timedelta(hours=6)


class SourceError(Exception):
    """GitLab or GitHub could not answer, so the check cannot conclude."""


@dataclass(frozen=True)
class Finding:
    repo: str
    github: str
    state: str  # ok | pending | missing | stale
    detail: str = ""


def github_name(path: str) -> str:
    return GITHUB_NAMES.get(path, path.rsplit("/", 1)[-1])


def same_commit(left: tuple[str, str], right: tuple[str, str]) -> bool:
    """ios and macos mirrors rewrite history into LFS, so their SHAs never
    match; the subject and author date survive the rewrite."""
    (left_title, left_date), (right_title, right_date) = left, right
    return left_title == right_title and _instant(left_date) == _instant(right_date)


def _instant(iso: str) -> datetime:
    return datetime.fromisoformat(iso.replace("Z", "+00:00"))


def check(sources, now: datetime | None = None) -> list[Finding]:
    now = now or datetime.now(timezone.utc)
    projects = [p for p in sources.public_projects() if p not in NOT_MIRRORED]
    if not projects:
        raise SourceError(f"no public projects listed for gitlab.com/{GROUP}")
    github_repos = sources.github_repos()
    findings = []
    for path in projects:
        name = github_name(path)
        if name not in github_repos:
            findings.append(Finding(path, name, "missing", "no GitHub repository"))
            continue
        gitlab_sha = sources.gitlab_head(path)
        github_sha = sources.github_head(name)
        if gitlab_sha == github_sha:
            findings.append(Finding(path, name, "ok"))
            continue
        title, authored, committed = sources.gitlab_commit(path, gitlab_sha)
        if github_sha and same_commit((title, authored), sources.github_commit(name, github_sha)):
            findings.append(Finding(path, name, "ok", "history rewritten into LFS"))
        elif now - _instant(committed) < GRACE:
            findings.append(Finding(path, name, "pending",
                                    f"main {gitlab_sha[:8]} committed under {GRACE} ago"))
        else:
            findings.append(Finding(path, name, "stale",
                                    f"GitLab main {gitlab_sha[:8]}, GitHub main "
                                    f"{(github_sha or 'none')[:8]}"))
    return findings


class LiveSources:
    def __init__(self, github_token: str | None = None):
        self.github_token = github_token

    def _get(self, url: str, headers: dict[str, str] | None = None):
        request = urllib.request.Request(url, headers={"User-Agent": "vauchi-mirror-check",
                                                       **(headers or {})})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response), response.headers
        except urllib.error.HTTPError as error:
            raise SourceError(f"{url}: HTTP {error.code}") from error
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            raise SourceError(f"{url}: {error}") from error

    def _github(self, url: str):
        headers = {"Accept": "application/vnd.github+json"}
        if self.github_token:
            headers["Authorization"] = f"Bearer {self.github_token}"
        return self._get(url, headers)

    @staticmethod
    def _project(path: str) -> str:
        return urllib.parse.quote(f"{GROUP}/{path}", safe="")

    @staticmethod
    def _ls_remote_main(url: str) -> str | None:
        env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
        result = subprocess.run(["git", "ls-remote", url, "refs/heads/main"],
                                capture_output=True, text=True, timeout=60, env=env)
        if result.returncode != 0:
            raise SourceError(f"git ls-remote {url}: {result.stderr.strip()}")
        return result.stdout.split()[0] if result.stdout.strip() else None

    def public_projects(self) -> list[str]:
        paths, page = [], "1"
        while page:
            data, headers = self._get(
                f"{GITLAB_API}/groups/{GROUP}/projects?visibility=public"
                f"&include_subgroups=true&archived=false&per_page=100&page={page}")
            paths += [p["path_with_namespace"].removeprefix(f"{GROUP}/") for p in data]
            page = headers.get("X-Next-Page", "")
        return sorted(paths)

    def github_repos(self) -> set[str]:
        names, url = set(), f"{GITHUB_API}/orgs/{GROUP}/repos?per_page=100"
        while url:
            data, headers = self._github(url)
            names |= {r["name"] for r in data}
            url = _next_link(headers.get("Link", ""))
        return names

    def gitlab_head(self, path: str) -> str:
        sha = self._ls_remote_main(f"https://gitlab.com/{GROUP}/{path}.git")
        if not sha:
            raise SourceError(f"gitlab.com/{GROUP}/{path} has no main branch")
        return sha

    def github_head(self, name: str) -> str | None:
        return self._ls_remote_main(f"https://github.com/{GROUP}/{name}.git")

    def gitlab_commit(self, path: str, sha: str) -> tuple[str, str, str]:
        data, _ = self._get(f"{GITLAB_API}/projects/{self._project(path)}/repository/commits/{sha}")
        return data["title"], data["authored_date"], data["committed_date"]

    def github_commit(self, name: str, sha: str) -> tuple[str, str]:
        data, _ = self._github(f"{GITHUB_API}/repos/{GROUP}/{name}/commits/{sha}")
        return data["commit"]["message"].split("\n", 1)[0], data["commit"]["author"]["date"]


def _next_link(link_header: str) -> str:
    for part in link_header.split(","):
        url, _, rel = part.partition(";")
        if rel.strip() == 'rel="next"':
            return url.strip().strip("<>")
    return ""


def main(argv: list[str], sources=None, now: datetime | None = None) -> int:
    if argv:
        print(__doc__.strip())
        return 2
    sources = sources or LiveSources(os.environ.get("GITHUB_TOKEN") or None)
    try:
        findings = check(sources, now)
    except SourceError as error:
        print(f"ERROR: could not check the GitHub mirrors: {error}")
        return 2
    for finding in findings:
        if finding.state != "ok":
            print(f"{finding.state.upper()} {finding.repo} -> github.com/{GROUP}/"
                  f"{finding.github} ({finding.detail})")
    in_sync = sum(f.state == "ok" for f in findings)
    pending = sum(f.state == "pending" for f in findings)
    summary = f"{in_sync} of {len(findings)} mirrors in sync"
    print(summary + (f", {pending} behind a main committed under {GRACE} ago" if pending else ""))
    return 1 if any(f.state in ("missing", "stale") for f in findings) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
