#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""Report quality-review candidates in tracked local working-tree source."""

import argparse
import collections
import json
import os
import subprocess
import sys
from pathlib import Path

from quality_scan_patterns import (
    DEPENDENCY_PARTS, GENERATED_HEADER, SOURCE_EXTENSIONS, candidates,
)
from quality_scan_complexity import measure

MAX_SOURCE_BYTES = 2_000_000


def git(repo, *args):
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, timeout=30, check=False,
    )
    if result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"Git inventory failed for {repo}: {detail}")
    return result.stdout


def repositories(workspace, requested):
    if not workspace.is_dir() or not (workspace / ".git").exists():
        raise ValueError(f"Workspace is not a Git repository: {workspace}")
    available = {"root": workspace}
    available.update({
        p.name: p for p in sorted(workspace.iterdir())
        if not p.is_symlink() and p.is_dir() and (p / ".git").exists()
    })
    if requested == ["all"]:
        return available.items()
    for name in requested:
        if name not in available:
            raise ValueError(f"Unknown repository: {name}")
    return [(name, available[name]) for name in dict.fromkeys(requested)]


def source_text(path, relative):
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        return None, "symlink"
    if not path.is_file():
        raise ValueError(f"Tracked source is missing or unreadable: {path}")
    if DEPENDENCY_PARTS.intersection(Path(relative).parts):
        return None, "dependency-or-build-path"
    if path.stat().st_size > MAX_SOURCE_BYTES:
        return None, "over-2MB"
    raw = path.read_bytes()
    if b"\x00" in raw:
        return None, "binary"
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None, "non-UTF8"
    first_line = text.partition("\n")[0]
    if GENERATED_HEADER.search(first_line):
        return None, "generated-first-line"
    return text, None


def scan(workspace, requested, complexity=False):
    inventory, findings, rust_sources = [], [], []
    for name, repo in repositories(workspace, requested):
        actual_root = Path(os.fsdecode(git(repo, "rev-parse", "--show-toplevel")).strip())
        if actual_root.resolve() != repo.resolve():
            raise ValueError(f"Invalid Git repository at {repo}: resolves to {actual_root}")
        row = {
            "name": name, "head": git(repo, "rev-parse", "HEAD").decode().strip(),
            "dirty": bool(git(repo, "status", "--porcelain", "--untracked-files=no")),
            "source_files": 0, "scanned_files": 0, "excluded": [],
            "extensions": collections.Counter(),
        }
        tracked = sorted(filter(None, git(repo, "ls-files", "-z").split(b"\x00")))
        for entry in tracked:
            relative = os.fsdecode(entry)
            path = repo / relative
            if path.suffix not in SOURCE_EXTENSIONS:
                continue
            row["source_files"] += 1
            display = path.relative_to(workspace).as_posix()
            text, reason = source_text(path, relative)
            if reason:
                row["excluded"].append({"path": display, "reason": reason})
                continue
            row["scanned_files"] += 1
            row["extensions"][path.suffix] += 1
            findings.extend(candidates(text, display))
            if complexity and path.suffix == ".rs":
                rust_sources.append({"path": display, "source": text})
        inventory.append(row)
    findings.sort(key=lambda hit: (hit["path"], hit["line"], hit["rule"]))
    report = {
        "schema_version": 1, "advisory": True,
        "scope": "tracked local working-tree source; candidates require review",
        "repositories": inventory,
        "scanned_files": sum(row["scanned_files"] for row in inventory),
        "candidate_count": len(findings), "candidates": findings,
        "rule_counts": collections.Counter(hit["rule"] for hit in findings),
    }
    if complexity:
        report["complexity"] = measure(workspace, rust_sources)
    return report


def print_summary(report):
    print(f"Quality scan: {len(report['repositories'])} repositories, "
          f"{report['scanned_files']} files, {report['candidate_count']} candidates")
    print("Advisory: review candidates against requirements; this is not AI attribution.")
    for row in report["repositories"]:
        print(f"  {row['name']}: {row['scanned_files']} scanned, "
              f"{len(row['excluded'])} excluded, "
              f"HEAD={row['head'][:12]}, dirty={row['dirty']}")
        for skipped in row["excluded"]:
            print(f"    excluded {skipped['path']}: {skipped['reason']}")
    for rule, count in sorted(report["rule_counts"].items()):
        print(f"  {rule}: {count}")
    for hit in report["candidates"][:20]:
        print(f"  {hit['path']}:{hit['line']}: {hit['rule']}")
    if len(report["candidates"]) > 20:
        print("  Showing first 20 candidates; use --json for the complete report.")
    if "complexity" in report:
        metric = report["complexity"]
        print(f"Rust complexity: {metric['files_analyzed']}/{metric['files_requested']} files, "
              f"{len(metric['functions'])} functions/closures; macros are unexpanded.")
        ranked = sorted(metric["functions"], key=lambda f: (-f["cyclomatic"], -f["max_nesting"]))
        for function in ranked[:10]:
            print(f"  {function['path']}:{function['line']}: {function['name']} "
                  f"cyclomatic={function['cyclomatic']} nesting={function['max_nesting']}")
        for failure in metric["failures"]:
            print(f"  complexity unavailable: {failure['path']}: {failure['error']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", nargs="*", default=["all"],
                        help="all (default), root, or local repository names")
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--json", action="store_true", help="emit full machine-readable report")
    parser.add_argument("--complexity", action="store_true",
                        help="add Rust function complexity (requires the built analyzer)")
    args = parser.parse_args()
    try:
        report = scan(args.workspace.resolve(), args.repo, args.complexity)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"quality-scan: {error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_summary(report)
    if args.complexity and report["complexity"]["failures"]:
        print("quality-scan: complexity coverage is incomplete; see failures", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
