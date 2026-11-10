#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""When each skill and just recipe was last used, from the hook event log.

The log-skill-use and log-just-use hooks append `skill-use` and `just-use`
events to `.claude/.session-errors`; this prints one line per name with its
last date and count, never-used names first, so pruning the catalogue goes
by date instead of by guess (vauchi/private#1198).

Usage: last-used.py [--log <file>]... [--skills a,b] [--recipes a,b]
Defaults: the workspace's own log; the skills under .claude/skills and the
recipes `just --summary` lists.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

CATEGORIES = {"skill-use": ("skill", "skill"), "just-use": ("recipe", "recipe")}


def read_logs(paths):
    for path in paths:
        try:
            with open(path, encoding="utf-8", errors="replace") as stream:
                yield from stream
        except OSError:
            continue


def tally(lines):
    result = {"skill": {}, "recipe": {}}
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict) or event.get("category") not in CATEGORIES:
            continue
        kind, field = CATEGORIES[event["category"]]
        name, day = event.get(field), str(event.get("ts", ""))[:10]
        if not name or not day:
            continue
        last, count = result[kind].get(name, ("", 0))
        result[kind][name] = (max(last, day), count + 1)
    return result


def render(tallied, skills, recipes):
    rows = []
    for kind, names in (("skill", skills), ("recipe", recipes)):
        seen = tallied[kind]
        for name in sorted(set(names) | set(seen)):
            last, count = seen.get(name, ("", 0))
            rows.append((last, kind, name, count))
    rows.sort(key=lambda r: (r[0], r[1], r[2]))
    return "\n".join(
        f"{kind}  {name}  never" if not last else f"{kind}  {name}  {last}  {count}"
        for last, kind, name, count in rows)


def workspace_skills(root):
    skills = root / ".claude" / "skills"
    return sorted(p.name for p in skills.iterdir() if p.is_dir()) if skills.is_dir() else []


def workspace_recipes(root):
    try:
        out = subprocess.run(["just", "--summary"], cwd=root, capture_output=True,
                             text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return out.stdout.split() if out.returncode == 0 else []


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="When each skill and just recipe was last used")
    parser.add_argument("--log", action="append", default=[])
    parser.add_argument("--skills", default=None, help="comma-separated; default: .claude/skills")
    parser.add_argument("--recipes", default=None, help="comma-separated; default: just --summary")
    parser.add_argument("--root", default=os.getcwd())
    options = parser.parse_args(argv)
    root = Path(options.root)
    logs = [Path(p) for p in options.log] or [root / ".claude" / ".session-errors"]
    skills = (options.skills.split(",") if options.skills is not None
              else workspace_skills(root))
    recipes = (options.recipes.split(",") if options.recipes is not None
               else workspace_recipes(root))
    print(render(tally(read_logs(logs)), [s for s in skills if s], [r for r in recipes if r]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
