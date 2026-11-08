#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
"""Keep cargo-deny's git sources on one reviewed list (vauchi/private#1162).

At Core v0.101.0 a new git dependency (the spake2 fork) passed Core and
then failed `cargo deny` in four consumers, each fixed by hand after the
tag. Every repository's `deny.toml` must deny unknown git sources and allow
exactly those in `policy/allowed-git-sources.txt` (decision 7: the file
stays the repository's own, so a local `cargo deny` reads what CI reads).
With that, a repository's own cargo-deny job refuses an unreviewed source
on the MR that adds it, Core's included, before any tag (decision 3), and
a reviewed source is already allowed in every consumer when Core starts
to take it. Adding a source is one reviewed change to the list.

Usage:
    check-allow-git.py --list LIST DENY_TOML...
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


def deny_drift(path: Path, listed: set[str]) -> list[str]:
    with path.open("rb") as handle:
        sources = tomllib.load(handle).get("sources", {})
    problems = []
    unknown_git = sources.get("unknown-git", "warn")
    if unknown_git != "deny":
        problems.append(f'set unknown-git = "deny" (is "{unknown_git}")')
    allowed = set(sources.get("allow-git", []))
    problems += [f'add "{source}"' for source in sorted(listed - allowed)]
    problems += [
        f'remove "{source}" (not in the reviewed list)' for source in sorted(allowed - listed)
    ]
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Keep cargo-deny git sources on one reviewed list.")
    parser.add_argument("--list", required=True, type=Path, dest="list_path")
    parser.add_argument("deny_files", nargs="+", type=Path)
    args = parser.parse_args(argv)

    listed = read_list(args.list_path)
    failed = False
    for path in args.deny_files:
        problems = deny_drift(path, listed)
        for problem in problems:
            print(f"FAIL: {path}: {problem}", file=sys.stderr)
        if not problems:
            print(f"OK: {path}")
        failed = failed or bool(problems)
    if failed:
        print(
            f"Fix: match [sources] to {args.list_path}, or add a reviewed source there "
            "first (vauchi/private#1162).",
            file=sys.stderr,
        )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
