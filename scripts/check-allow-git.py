#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
"""Keep cargo-deny's git sources on one reviewed list (vauchi/private#1162).

At Core v0.101.0 a new git dependency (the spake2 fork) passed Core and
then failed `cargo deny` in four consumers, each fixed by hand after the
tag. The reviewed list in `policy/allowed-git-sources.txt` closes both
ends: every repository's `deny.toml` allows exactly the listed sources
(decision 7: the file stays the repository's own, so a local `cargo deny`
reads what CI reads), and Core's release fails when its lockfile takes a
git source the list lacks (decision 3). Adding a source is one reviewed
change to the list.

Usage:
    check-allow-git.py deny --list LIST DENY_TOML...
    check-allow-git.py lock --list LIST CARGO_LOCK...
"""
from __future__ import annotations

import argparse
import sys
import tomllib
from pathlib import Path


def read_list(path: Path) -> set[str]:
    entries = set()
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            entries.add(line)
    return entries


def deny_allow_git(path: Path) -> set[str]:
    with path.open("rb") as handle:
        config = tomllib.load(handle)
    return set(config.get("sources", {}).get("allow-git", []))


def deny_drift(path: Path, listed: set[str]) -> list[str]:
    allowed = deny_allow_git(path)
    problems = [f'add "{source}"' for source in sorted(listed - allowed)]
    problems += [
        f'remove "{source}" (not in the reviewed list)' for source in sorted(allowed - listed)
    ]
    return problems


def normalise_lock_source(source: str) -> str:
    """`git+https://host/repo?tag=x#sha` -> `https://host/repo.git`."""
    url = source.removeprefix("git+").split("#", 1)[0].split("?", 1)[0]
    return url if url.endswith(".git") else f"{url}.git"


def lock_git_sources(path: Path) -> set[str]:
    with path.open("rb") as handle:
        lock = tomllib.load(handle)
    return {
        normalise_lock_source(package["source"])
        for package in lock.get("package", [])
        if package.get("source", "").startswith("git+")
    }


def unreviewed_lock_sources(path: Path, listed: set[str]) -> list[str]:
    return sorted(lock_git_sources(path) - listed)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Keep cargo-deny git sources on one reviewed list.")
    parser.add_argument("mode", choices=["deny", "lock"])
    parser.add_argument("--list", required=True, type=Path, dest="list_path")
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args(argv)

    listed = read_list(args.list_path)
    failed = False
    for path in args.files:
        if args.mode == "deny":
            problems = deny_drift(path, listed)
        else:
            problems = [
                f'takes "{source}", which the reviewed list lacks'
                for source in unreviewed_lock_sources(path, listed)
            ]
        for problem in problems:
            print(f"FAIL: {path}: {problem}", file=sys.stderr)
        failed = failed or bool(problems)
        if not problems:
            print(f"OK: {path}")
    if failed:
        print(
            f"Fix: match allow-git to {args.list_path}, or add a reviewed source there "
            "first (vauchi/private#1162).",
            file=sys.stderr,
        )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
