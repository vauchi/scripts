#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
"""Diff two shells' command-envelope outlines, surface by surface.

An outline is a command batch with every text replaced by its length
(vauchi_app::ui::command_outline). Core writes one per catalog screen to
core/vauchi-app/fixtures/journeys/screen_outline_v1.json; a dev build of a
shell logs one per batch under the target `vauchi.presentation.outline`
(adb logcat, journalctl, a terminal). This script reads either shape from
each side, keys every outline by the id of the surface it replaces, and
prints each structural difference as a JSON path (private#1206, UI/UX
clarity addendum, step 2).

Usage:
    envelope-outline-diff.py <left> <right> [--only <surface_id>]

Exit status: 0 when every shared surface has the same outline, 1 when a
difference is found, 2 on unusable input.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

LOG_MARK = "vauchi.presentation.outline"


def outlines_from_text(text: str) -> dict[str, object]:
    """Return {surface_id: outline} from a fixture file or a log capture."""
    stripped = text.strip()
    if stripped.startswith("{"):
        try:
            doc = json.loads(stripped)
        except json.JSONDecodeError:
            doc = None
        if isinstance(doc, dict) and all(isinstance(v, list) for v in doc.values()):
            return {key_of(v, fallback=k): v for k, v in doc.items()}
    found: dict[str, object] = {}
    for line in text.splitlines():
        if LOG_MARK not in line:
            continue
        start = line.find("[")
        if start < 0:
            continue
        try:
            batch = json.loads(line[start:])
        except json.JSONDecodeError:
            continue
        found[key_of(batch, fallback=f"batch-{len(found)}")] = batch
    return found


def key_of(batch: object, fallback: str) -> str:
    """The id of the surface a batch replaces, else the fallback."""
    if isinstance(batch, list):
        for command in batch:
            if isinstance(command, dict) and "ReplaceSurface" in command:
                body = command["ReplaceSurface"]
                if isinstance(body, dict):
                    sid = body.get("surface_id")
                    if isinstance(sid, str):
                        return sid
    return fallback


def differences(left: object, right: object, path: str = "") -> list[str]:
    if isinstance(left, dict) and isinstance(right, dict):
        out: list[str] = []
        for key in sorted(set(left) | set(right)):
            here = f"{path}/{key}"
            if key not in left:
                out.append(f"{here}: only on the right")
            elif key not in right:
                out.append(f"{here}: only on the left")
            else:
                out.extend(differences(left[key], right[key], here))
        return out
    if isinstance(left, list) and isinstance(right, list):
        out = []
        for i in range(max(len(left), len(right))):
            here = f"{path}[{i}]"
            if i >= len(left):
                out.append(f"{here}: only on the right")
            elif i >= len(right):
                out.append(f"{here}: only on the left")
            else:
                out.extend(differences(left[i], right[i], here))
        return out
    if left != right:
        return [f"{path}: {json.dumps(left)} != {json.dumps(right)}"]
    return []


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("left", type=Path)
    parser.add_argument("right", type=Path)
    parser.add_argument("--only", help="compare this surface id alone")
    args = parser.parse_args(argv)

    sides = []
    for side in (args.left, args.right):
        if not side.is_file():
            print(f"ERROR: {side} is not a file", file=sys.stderr)
            return 2
        outlines = outlines_from_text(side.read_text(encoding="utf-8"))
        if not outlines:
            print(f"ERROR: no outline found in {side}", file=sys.stderr)
            return 2
        sides.append(outlines)
    left, right = sides

    shared = sorted(set(left) & set(right))
    if args.only:
        shared = [s for s in shared if s == args.only]
    if not shared:
        print("ERROR: the two sides share no surface id", file=sys.stderr)
        return 2

    status = 0
    for sid in shared:
        diff = differences(left[sid], right[sid])
        if diff:
            status = 1
            print(f"{sid}: {len(diff)} difference(s)")
            for line in diff:
                print(f"  {line}")
        else:
            print(f"{sid}: same outline")
    only_left = sorted(set(left) - set(right))
    only_right = sorted(set(right) - set(left))
    if only_left:
        print(f"only on the left: {', '.join(only_left)}")
    if only_right:
        print(f"only on the right: {', '.join(only_right)}")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
