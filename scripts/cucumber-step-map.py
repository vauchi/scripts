#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Map Gherkin scenarios to the cucumber step definitions that run them.

Two questions the cucumber runner cannot answer on its own
(vauchi/private#960, #862):

1. Which scenarios pass without asserting anything, because every `Then`
   step they reach has an empty body?
2. Which empty step functions are worth filling first, because the most
   scenarios share them, and which annotated `@scenario:` test already
   proves each of those scenarios?

    cucumber-step-map.py classify --steps core/vauchi-core/tests/steps \\
        --features features [--run cucumber-output.txt]
    cucumber-step-map.py worklist --steps ... --features ... [--tests core ...]
    cucumber-step-map.py empty-steps --steps ...   # exits 1 when any step is empty

`classify` matches every non-planned scenario's steps against the
definitions (literal, `expr` and `regex` attributes) and reports, per
scenario: `unwired` (a step has no definition), `vacuous` (wired and every
`Then` step is empty), `asserting` (wired and at least one `Then` has a
body), or `unclassified` (a step the matcher could not resolve). With
`--run`, the scenarios are read from the runner's output instead, with the
step texts as it expanded them, so the result describes what CI executed.
"""

from __future__ import annotations

import argparse
import glob
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

STEP_ATTR = re.compile(
    r'#\[(given|when|then)\(\s*(?:(regex|expr)\s*=\s*)?r?#?"((?:[^"\\]|\\.)*)"#?\s*\)\]'
    r"\s*(?:async\s+)?fn\s+(\w+)\s*\([^)]*\)\s*(?:->\s*[^{]+)?\{(\s*)(\}?)",
    re.S,
)
SCENARIO_LINE = re.compile(r"^\s*(Scenario Outline|Scenario|Example):\s*(.*)$")
STEP_LINE = re.compile(r"^\s*(Given|When|Then|And|But)\s+(.*)$")
RUN_SCENARIO = re.compile(r"^\s*Scenario(?: Outline)?: (.*)$")
RUN_STEP = re.compile(r"^\s*(✔>?|\?|✘)\s+(Given|When|Then|And|But)\s+(.*)$")
ANNOTATION = re.compile(r"@scenario:\s*([\w-]+)(?:\.feature)?\s*(?:::|:|-)\s*(.+?)\s*$")


@dataclass
class StepDef:
    kind: str
    pattern: re.Pattern
    empty: bool
    name: str
    file: str
    text: str


@dataclass
class Scenario:
    feature: str
    name: str
    tags: set
    steps: list = field(default_factory=list)  # (kind, text)


def expression_to_regex(mode: str | None, pattern: str) -> str:
    if mode == "regex":
        return pattern
    rx = re.escape(pattern)
    rx = re.sub(r"\\\{(?:int|word|float)\\\}", r"\\S+", rx)
    rx = re.sub(r"\\\{string\\\}", r'"[^"]*"', rx)
    rx = re.sub(r"\\\{[^}]*\\\}", r".+?", rx)
    return "^" + rx + "$"


def load_steps(steps_dir: Path) -> list[StepDef]:
    defs: list[StepDef] = []
    for path in sorted(steps_dir.glob("*.rs")):
        src = path.read_text(encoding="utf-8")
        for m in STEP_ATTR.finditer(src):
            kind, mode, pattern, name, _ws, close = m.groups()
            try:
                compiled = re.compile(expression_to_regex(mode, pattern))
            except re.error:
                continue
            defs.append(StepDef(kind, compiled, close == "}", name, path.name, pattern))
    return defs


def load_scenarios(features_dir: Path) -> list[Scenario]:
    scenarios: list[Scenario] = []
    for path in sorted(features_dir.glob("*.feature")):
        feature = path.stem
        feature_tags: set = set()
        pending: list = []
        current: Scenario | None = None
        last_kind = None
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("@"):
                pending += stripped.split()
                continue
            if stripped.startswith("Feature:"):
                feature_tags = set(pending)
                pending = []
                continue
            m = SCENARIO_LINE.match(line)
            if m:
                current = Scenario(feature, m.group(2).strip(), set(pending) | feature_tags)
                scenarios.append(current)
                pending = []
                last_kind = None
                continue
            s = STEP_LINE.match(line)
            if s and current is not None:
                kind = s.group(1).lower()
                if kind in ("and", "but"):
                    kind = last_kind or "given"
                last_kind = kind
                current.steps.append((kind, s.group(2).strip()))
    return scenarios


RUN_FEATURE = re.compile(r"^Feature: (.*)$")


def scenarios_from_run(run_output: Path, features_dir: Path) -> list[Scenario]:
    """The scenarios the cucumber writer reported with every step passed, with
    the step texts as the runner expanded them (outline placeholders filled in),
    so that classification describes what CI executed."""
    stems = {}
    for path in features_dir.glob("*.feature"):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("Feature:"):
                stems[line[len("Feature:"):].strip()] = path.stem
                break
    passed: list[Scenario] = []
    feature = None
    current: Scenario | None = None
    ok = True
    last_kind = None

    def flush() -> None:
        if current is not None and ok and current.steps:
            passed.append(current)

    for line in run_output.read_text(encoding="utf-8", errors="replace").splitlines():
        f = RUN_FEATURE.match(line)
        if f:
            flush()
            current, ok = None, True
            feature = stems.get(f.group(1).strip(), f.group(1).strip())
            continue
        m = RUN_SCENARIO.match(line)
        if m:
            flush()
            current, ok, last_kind = Scenario(feature or "", m.group(1).strip(), set()), True, None
            continue
        s = RUN_STEP.match(line)
        if s and current is not None:
            mark, kw, text = s.groups()
            if not mark.startswith("\u2714"):
                ok = False
            kind = kw.lower()
            if kind in ("and", "but"):
                kind = last_kind or "given"
            last_kind = kind
            current.steps.append((kind, text.strip()))
    flush()
    return passed


def classify(scenario: Scenario, defs: list[StepDef], from_run: bool = False) -> tuple[str, list]:
    """Returns (verdict, matched definitions per step). A scenario taken from a
    run passed every step, so a step without a definition here is one this
    matcher could not resolve, not an unwired one."""
    matched = []
    for kind, text in scenario.steps:
        hits = [d for d in defs if d.pattern.search(text)]
        matched.append(hits)
    if not scenario.steps or any(not hits for hits in matched):
        return "unclassified" if from_run else "unwired", matched
    thens = [hits for (kind, _), hits in zip(scenario.steps, matched) if kind == "then"]
    if thens and all(all(d.empty for d in hits) for hits in thens):
        return "vacuous", matched
    return "asserting", matched


def load_annotations(test_roots: list[Path]) -> dict:
    """(feature stem, scenario name) -> list of 'file:line' annotation sites."""
    found: dict = defaultdict(list)
    for root in test_roots:
        for path in root.rglob("*.rs"):
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except (UnicodeDecodeError, OSError):
                continue
            for n, line in enumerate(lines, 1):
                m = ANNOTATION.search(line)
                if m:
                    found[(m.group(1), m.group(2).lower())].append(f"{path}:{n}")
    return found


def cmd_classify(args) -> int:
    defs = load_steps(args.steps)
    if args.run:
        scenarios = scenarios_from_run(args.run, args.features)
    else:
        scenarios = [s for s in load_scenarios(args.features) if not args.skip_tags & s.tags]
    counts: dict = defaultdict(int)
    rows = []
    for s in scenarios:
        verdict, _ = classify(s, defs, from_run=bool(args.run))
        counts[verdict] += 1
        rows.append({"feature": s.feature, "scenario": s.name, "verdict": verdict})
    if args.json:
        json.dump({"counts": counts, "scenarios": rows}, sys.stdout, indent=1)
        print()
    else:
        print(f"scenarios considered: {len(scenarios)}")
        for verdict in ("asserting", "vacuous", "unwired", "unclassified"):
            print(f"  {verdict}: {counts.get(verdict, 0)}")
        for r in rows:
            if r["verdict"] == "vacuous":
                print(f"  VACUOUS: {r['feature']} :: {r['scenario']}")
    return 1 if counts.get("vacuous") else 0


def cmd_worklist(args) -> int:
    defs = load_steps(args.steps)
    scenarios = [s for s in load_scenarios(args.features) if not args.skip_tags & s.tags]
    annotations = load_annotations(args.tests) if args.tests else {}
    uses: dict = defaultdict(list)
    for s in scenarios:
        for kind, text in s.steps:
            for d in defs:
                if d.empty and d.pattern.search(text):
                    uses[d.name].append(s)
    ranked = sorted(((d for d in defs if d.empty)), key=lambda d: -len(uses[d.name]))
    print(f"empty step functions: {len(ranked)} of {len(defs)}")
    for d in ranked:
        users = uses[d.name]
        print(f"\n{len(users):3} scenario(s)  {d.file}::{d.name}  [{d.kind}] \"{d.text}\"")
        for s in users[: args.limit]:
            sites = annotations.get((s.feature, s.name.lower()), [])
            proof = f"  proof: {sites[0]}" + (f" (+{len(sites) - 1})" if len(sites) > 1 else "") if sites else "  proof: none annotated"
            print(f"      {s.feature} :: {s.name}{proof}")
    return 0


def cmd_empty_steps(args) -> int:
    defs = load_steps(args.steps)
    empty = [d for d in defs if d.empty]
    for d in empty:
        print(f"{d.file}::{d.name}")
    print(f"empty step functions: {len(empty)} of {len(defs)}")
    return 1 if empty else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("classify", "worklist", "empty-steps"):
        p = sub.add_parser(name)
        p.add_argument("--steps", type=Path, required=True, help="directory of cucumber step definition .rs files")
        if name != "empty-steps":
            p.add_argument("--features", type=Path, required=True)
            p.add_argument("--skip-tags", default="@planned,@wip,@ui",
                           help="comma-separated tags whose scenarios the runner skips")
        if name == "classify":
            p.add_argument("--run", type=Path, help="saved cucumber runner output; classify only its passed scenarios")
            p.add_argument("--json", action="store_true")
        if name == "worklist":
            p.add_argument("--tests", type=Path, nargs="*", default=[], help="roots to scan for @scenario: annotations")
            p.add_argument("--limit", type=int, default=5, help="scenarios listed per step")
    args = ap.parse_args()
    if hasattr(args, "skip_tags"):
        args.skip_tags = {t.strip() for t in args.skip_tags.split(",") if t.strip()}
    return {"classify": cmd_classify, "worklist": cmd_worklist, "empty-steps": cmd_empty_steps}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
