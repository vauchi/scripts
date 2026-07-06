#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Cross-language Humble UI ratchet for Vauchi frontends.

Scans handwritten frontend source for patterns that leak domain decisions,
domain vocabulary, or domain-string interpretation into the view layer. In
snapshot mode it emits a JSON count per rule. In check mode it compares the
live counts against a baseline and fails if any rule's count has increased.

Usage:
    humble_check.py --repo ios --workspace-root /path/to/workspace
    humble_check.py --repo ios --workspace-root /path/to/workspace --check baseline.json
"""

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_LOOKBACK = 10
DEFAULT_LOOKAHEAD = 3


def load_config(config_path: Path) -> dict:
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_baseline(baseline_path: Path) -> dict:
    with open(baseline_path, "r", encoding="utf-8") as f:
        return json.load(f)


def should_exclude(path: Path, exclude_dirs: set[str]) -> bool:
    parts = path.parts
    return any(part in exclude_dirs for part in parts)


def find_files(root: Path, extensions: set[str], exclude_dirs: set[str]) -> list[Path]:
    if not root.exists():
        return []
    files = []
    for item in root.rglob("*"):
        if not item.is_file():
            continue
        if item.suffix not in extensions:
            continue
        if should_exclude(item, exclude_dirs):
            continue
        files.append(item)
    return files


def has_humble_exception(lines: list[str], match_line_index: int, lookback: int, lookahead: int) -> bool:
    start = max(0, match_line_index - lookback)
    end = min(len(lines) - 1, match_line_index + lookahead)
    for i in range(start, end + 1):
        if "TODO(HUMBLE)" in lines[i] or "HUMBLE-EXCEPTION" in lines[i]:
            return True
    return False


def scan_file(path: Path, rules: dict[str, dict], lookback: int, lookahead: int) -> dict[str, list[tuple[int, str]]]:
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.read().splitlines()
    except OSError:
        return {}

    compiled = {
        name: re.compile("|".join(f"(?:{p})" for p in rule["patterns"]))
        for name, rule in rules.items()
    }

    findings = {name: [] for name in rules}
    for idx, line in enumerate(lines):
        for name, regex in compiled.items():
            if not regex.search(line):
                continue
            if has_humble_exception(lines, idx, lookback, lookahead):
                continue
            findings[name].append((idx + 1, line.strip()))
    return findings


def rule_message(rules: dict[str, dict], name: str) -> str:
    return rules[name].get("message", name)


def scan_repo(workspace_root: Path, repo: str, repo_path: Path | None, config: dict, lookback: int, lookahead: int) -> dict:
    repo_config = config["repos"][repo]
    source_roots = repo_config["source_roots"]
    extensions = set(repo_config.get("extensions", []))
    exclude_dirs = set(repo_config.get("exclude_dirs", []))
    rules = repo_config["rules"]

    counts = {name: 0 for name in rules}
    examples: dict[str, list[tuple[str, int, str]]] = {name: [] for name in rules}

    for rel in source_roots:
        if repo_path is not None:
            root = repo_path / rel
        else:
            root = workspace_root / rel
        for file in find_files(root, extensions, exclude_dirs):
            display = file.relative_to(repo_path or workspace_root)
            findings = scan_file(file, rules, lookback, lookahead)
            for name, matches in findings.items():
                counts[name] += len(matches)
                for line_no, line_text in matches:
                    if len(examples[name]) < 5:
                        examples[name].append((str(display), line_no, line_text))
    return {"counts": counts, "examples": examples, "rules": rules}


def emit_snapshot(repo: str, result: dict) -> str:
    captured_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    snapshot = {
        "schema_version": 1,
        "captured_at": captured_at,
        "repo": repo,
        "totals": result["counts"],
    }
    return json.dumps(snapshot, indent=2)


def check_baseline(repo: str, result: dict, baseline: dict) -> int:
    current = result["counts"]
    repo_baseline = baseline.get("repos", {}).get(repo, {})
    regressions = []
    for name, count in current.items():
        base = repo_baseline.get(name, 0)
        if count > base:
            regressions.append((name, base, count))

    if not regressions:
        print(f"humble_check ({repo}): OK — all rule counts at or below baseline")
        return 0

    print(f"humble_check ({repo}): {len(regressions)} rule(s) exceeded baseline", file=sys.stderr)
    for name, base, count in regressions:
        print(f"  [{name}] baseline {base}, now {count}: {rule_message(result['rules'], name)}", file=sys.stderr)
        for display, line_no, line_text in result["examples"].get(name, []):
            print(f"    {display}:{line_no}: {line_text[:120]}", file=sys.stderr)
    print("\nThe Humble UI deny-list ratchet may only drop. Fix new violations or update the baseline intentionally.", file=sys.stderr)
    return 1


def run(workspace_root: Path, repo: str, repo_path: Path | None, config: dict, lookback: int, lookahead: int, baseline: dict | None) -> int:
    if repo not in config["repos"]:
        print(f"humble_check: no rules configured for repo '{repo}'", file=sys.stderr)
        return 2

    result = scan_repo(workspace_root, repo, repo_path, config, lookback, lookahead)
    if baseline is None:
        print(emit_snapshot(repo, result))
        return 0
    return check_baseline(repo, result, baseline)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Cross-language Humble UI ratchet")
    parser.add_argument("--repo", required=True, help="Frontend repo name (e.g. ios, android)")
    parser.add_argument("--workspace-root", type=Path, help="Workspace root containing all repos")
    parser.add_argument("--repo-path", type=Path, help="Path to the repo itself (overrides workspace-root)")
    parser.add_argument("--config", type=Path, help="Path to humble_check_rules.json")
    parser.add_argument("--check", type=Path, metavar="BASELINE", help="Baseline JSON to ratchet against")
    parser.add_argument("--lookback", type=int, default=DEFAULT_LOOKBACK, help="Lines before a match to search for TODO(HUMBLE)")
    parser.add_argument("--lookahead", type=int, default=DEFAULT_LOOKAHEAD, help="Lines after a match to search for TODO(HUMBLE)")
    args = parser.parse_args(argv)

    script_dir = Path(__file__).resolve().parent
    workspace_root = args.workspace_root or (script_dir.parent.parent)
    config_path = args.config or (script_dir / "humble_check_rules.json")

    if not config_path.exists():
        print(f"humble_check: config not found: {config_path}", file=sys.stderr)
        return 2

    baseline = None
    if args.check:
        if not args.check.exists():
            print(f"humble_check: baseline not found: {args.check}", file=sys.stderr)
            return 2
        baseline = load_baseline(args.check)

    config = load_config(config_path)
    return run(workspace_root, args.repo, args.repo_path, config, args.lookback, args.lookahead, baseline)


if __name__ == "__main__":
    sys.exit(main())
