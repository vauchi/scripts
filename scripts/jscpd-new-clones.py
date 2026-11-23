#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Two duplication ratchets over two jscpd JSON reports.

Duplication must not grow: the branch's totals of clones and duplicated
lines may not exceed main's. A rename or a reformat leaves both as they
were; a new duplicate, or an old one that grows, raises them.

And no clone may be new:

jscpd's --baseline-from-ref matches a clone by its text, so a rename that
runs through code main already duplicated reports every such duplicate as
new (vauchi/private#1359: 44 on core!2411, all on main at the same lines).
So a clone jscpd flags as new is new here only if main's own report has no
clone of the same two files within LINE_SLACK lines of it, after mapping
files git saw renamed.

    jscpd-new-clones.py --branch BRANCH.json --main MAIN.json \\
        --name-status NAMES.txt [--allowed N]

NAMES.txt is `git diff --name-status -M <main> HEAD`. Exit 0 when
duplication did not grow and at most --allowed clones are new, 1
otherwise, 2 when a report cannot be read: a check that could not run
must not pass.
"""

import argparse
import json
import sys
from pathlib import Path

LINE_SLACK = 5


def renames_from_name_status(text):
    """New path -> old path, for every rename in `git diff --name-status -M`."""
    renames = {}
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) == 3 and fields[0].startswith("R"):
            renames[fields[2]] = fields[1]
    return renames


def _place(clone, renames):
    first, second = clone["firstFile"], clone["secondFile"]
    ends = sorted([
        (renames.get(first["name"], first["name"]), first["start"]),
        (renames.get(second["name"], second["name"]), second["start"]),
    ])
    return ends


def _same_place(branch_ends, main_ends):
    return all(
        name == main_name and abs(start - main_start) <= LINE_SLACK
        for (name, start), (main_name, main_start) in zip(branch_ends, main_ends)
    )


def new_clones(branch, main, renames):
    """The clones of `branch` that jscpd flags new and main had nowhere near."""
    main_places = [_place(clone, {}) for clone in main["duplicates"]]
    found = []
    for clone in branch["duplicates"]:
        if not clone.get("isNew"):
            continue
        place = _place(clone, renames)
        if not any(_same_place(place, main_place) for main_place in main_places):
            found.append(clone)
    return found


def growth(branch, main):
    """What grew between main's totals and the branch's, in words."""
    grew = []
    for key, words in (("clones", "clones"), ("duplicatedLines", "duplicated lines")):
        before = main["statistics"]["total"][key]
        after = branch["statistics"]["total"][key]
        if after > before:
            grew.append(f"{words} grew from {before} to {after}")
    return grew


def _load(path):
    report = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(report.get("duplicates"), list):
        raise ValueError(f"{path}: no duplicates list")
    total = report.get("statistics", {}).get("total", {})
    if not all(isinstance(total.get(key), int) for key in ("clones", "duplicatedLines")):
        raise ValueError(f"{path}: no totals of clones and duplicated lines")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--branch", required=True)
    parser.add_argument("--main", required=True)
    parser.add_argument("--name-status", required=True)
    parser.add_argument("--allowed", type=int, default=0)
    args = parser.parse_args(argv)
    try:
        branch = _load(args.branch)
        main_report = _load(args.main)
        renames = renames_from_name_status(Path(args.name_status).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"jscpd-new-clones: cannot read the reports: {error}", file=sys.stderr)
        return 2

    flagged = sum(1 for clone in branch["duplicates"] if clone.get("isNew"))
    found = new_clones(branch, main_report, renames)
    for clone in found:
        first, second = clone["firstFile"], clone["secondFile"]
        print(f"new clone: {first['name']}:{first['start']}-{first['end']}"
              f" ~ {second['name']}:{second['start']}-{second['end']} ({clone['lines']} lines)")
    print(f"jscpd-new-clones: {len(found)} new, of {flagged} jscpd flagged by text;"
          f" {flagged - len(found)} sit where main had the same duplicate (allowed: {args.allowed})")
    grew = growth(branch, main_report)
    for line in grew:
        print(f"jscpd-new-clones: duplication grew: {line}")
    totals = [branch["statistics"]["total"][k] for k in ("clones", "duplicatedLines")]
    main_totals = [main_report["statistics"]["total"][k] for k in ("clones", "duplicatedLines")]
    print(f"jscpd-new-clones: totals {totals[0]} clones, {totals[1]} duplicated lines"
          f" (main: {main_totals[0]}, {main_totals[1]})")
    return 1 if len(found) > args.allowed or grew else 0


if __name__ == "__main__":
    sys.exit(main())
