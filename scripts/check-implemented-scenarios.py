#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Fail when a Gherkin scenario tagged @implemented has no test naming it.

Contract (vauchi/private#268, owner decision 2026-10-10): a scenario tagged
@implemented needs at least one test annotated

    // @scenario: <feature file stem> :: <scenario name>

(`<stem>.feature:<name>` and a single `:` are accepted too) in any of the
given repositories. Names match ignoring case and runs of whitespace, never
wording. Scenarios untested when the check arrived are listed in the
baseline file, one `<stem> :: <name>` per line; the list may shrink, never
grow. Exit 0 pass, 1 an untested scenario outside the baseline (or, with
--strict, a stale baseline entry), 2 bad input.

Usage:
    check-implemented-scenarios.py --features DIR --baseline FILE
        [--strict | --write-baseline] REPO_DIR [REPO_DIR ...]
"""

import argparse
import os
import re
import sys
from pathlib import Path

SOURCE_SUFFIXES = {
    ".rs", ".swift", ".kt", ".kts", ".cs", ".ts", ".tsx", ".js", ".mjs",
    ".py", ".cpp", ".cc", ".h", ".hpp", ".sh",
}
SKIP_DIRS = {".git", "target", "node_modules", "build", ".build", "vendor"}
SCENARIO_LINE = re.compile(r"^\s*Scenario(?: Outline)?:\s*(.+?)\s*$")
ANNOTATION = re.compile(r"@scenario:\s*(.+?)\s*$")


def normalise(text: str) -> str:
    return " ".join(text.split()).lower()


def implemented_scenarios(features: Path) -> dict[tuple[str, str], str]:
    """(stem, normalised name) -> display name, for every @implemented scenario."""
    found: dict[tuple[str, str], str] = {}
    for path in sorted(features.glob("*.feature")):
        stem = path.stem
        tags: list[str] = []
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("@"):
                tags.extend(stripped.split())
                continue
            match = SCENARIO_LINE.match(line)
            if match:
                if "@implemented" in tags:
                    name = match.group(1)
                    found[(stem, normalise(name))] = f"{stem} :: {name}"
                tags = []
            elif stripped and not stripped.startswith("#"):
                tags = []
    return found


def parse_annotation(body: str) -> tuple[str, str] | None:
    if "::" in body:
        feature, _, name = body.partition("::")
    elif ":" in body:
        feature, _, name = body.partition(":")
    else:
        return None
    feature = feature.strip()
    if feature.endswith(".feature"):
        feature = feature[: -len(".feature")]
    if not feature or not name.strip():
        return None
    return feature, normalise(name)


def annotated_scenarios(repos: list[Path]) -> set[tuple[str, str]]:
    found: set[tuple[str, str]] = set()
    for repo in repos:
        for dirpath, dirnames, filenames in os.walk(repo):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for filename in filenames:
                if Path(filename).suffix not in SOURCE_SUFFIXES:
                    continue
                try:
                    text = Path(dirpath, filename).read_text(encoding="utf-8")
                except (UnicodeDecodeError, OSError):
                    continue
                if "@scenario:" not in text:
                    continue
                for line in text.splitlines():
                    match = ANNOTATION.search(line)
                    if match:
                        parsed = parse_annotation(match.group(1))
                        if parsed:
                            found.add(parsed)
    return found


def read_baseline(path: Path) -> dict[tuple[str, str], str]:
    entries: dict[tuple[str, str], str] = {}
    if not path.exists():
        return entries
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parsed = parse_annotation(line)
        if parsed:
            entries[parsed] = line
    return entries


BASELINE_HEADER = """\
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# @implemented scenarios that had no test naming them when
# check-implemented-scenarios.py arrived (vauchi/private#268). This list may
# only shrink: add a test annotated `// @scenario: <stem> :: <name>`, or
# retag the scenario @planned, then delete its line here.
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--features", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--strict", action="store_true",
                      help="also fail on baseline entries that no longer need to be there")
    mode.add_argument("--write-baseline", action="store_true",
                      help="rewrite the baseline to today's untested scenarios")
    parser.add_argument("repos", type=Path, nargs="+")
    args = parser.parse_args()

    if not any(args.features.glob("*.feature")):
        print(f"ERROR: no .feature files in {args.features}", file=sys.stderr)
        return 2
    for repo in args.repos:
        if not repo.is_dir():
            print(f"ERROR: {repo} is not a directory", file=sys.stderr)
            return 2

    implemented = implemented_scenarios(args.features)
    annotated = annotated_scenarios(args.repos)
    untested = {key: shown for key, shown in implemented.items() if key not in annotated}

    if args.write_baseline:
        lines = sorted(untested.values(), key=str.lower)
        args.baseline.write_text(BASELINE_HEADER + "".join(f"{line}\n" for line in lines))
        print(f"Wrote {len(lines)} untested @implemented scenarios to {args.baseline}")
        return 0

    baseline = read_baseline(args.baseline)
    new = sorted((shown for key, shown in untested.items() if key not in baseline), key=str.lower)
    stale = sorted((shown for key, shown in baseline.items() if key not in untested), key=str.lower)

    tested = len(implemented) - len(untested)
    print(f"{tested} of {len(implemented)} @implemented scenarios have a test; "
          f"{len(untested)} untested, {len(baseline)} in the baseline")
    if new:
        print(f"\n{len(new)} @implemented scenario(s) with no test naming them:")
        for shown in new:
            print(f"  {shown}")
        print("\nAdd a test annotated `// @scenario: <stem> :: <name>`, "
              "or tag the scenario @planned.")
    if stale:
        print(f"\n{len(stale)} baseline entr(ies) now tested or no longer @implemented "
              "- remove from the baseline:")
        for shown in stale:
            print(f"  {shown}")
    if new or (args.strict and stale):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
