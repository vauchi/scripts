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

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_LOOKBACK = 10
DEFAULT_LOOKAHEAD = 3

# Public boundary names retired by the generic Event -> Core -> Command[]
# contract.  These are intentionally checked only by the exact-zero release
# gate until each frontend's measured migration baseline is recorded.
RETIRED_BOUNDARY_PATTERNS = (
    re.compile(r"\bScreenModel\b"),
    re.compile(r"\bUserAction\b"),
    re.compile(r"\bActionResult\b"),
    re.compile(r"\bWorkflowEngine\b"),
    re.compile(r"\bAppEngine\b"),
    re.compile(r"\b(Component|Field|InfoItem|ScreenAction)\b"),
    re.compile(r"\b(dispatch_action|dispatch_user_action|handle_action|split_dispatch)\b"),
)


class VocabularyDriftError(Exception):
    """A boundary rule greps for a type name absent from the shared vocabulary."""


def _pattern_type_names(patterns: list[str]) -> set[str]:
    """Capitalised identifiers a `\\bWord\\b` pattern greps for.

    Lowercase literals (`visibility_label`, `handleAction`) are method and
    field spellings rather than boundary types, so they are not vocabulary
    entries and are skipped.
    """
    names = set()
    for pattern in patterns:
        for literal in re.findall(r"\\b([A-Za-z_][A-Za-z0-9_]*)\\b", pattern):
            if literal[:1].isupper():
                names.add(literal)
    return names


def validate_vocabulary_coverage(config: dict) -> None:
    """Keep `retired_boundary_vocabulary` the single list of retired names.

    Consumers that cannot grep repo sources — the Core schema test in
    `domain_vocabulary_boundary_tests.rs` — read the vocabulary instead of
    restating it. That only holds while the vocabulary covers every type the
    rules grep for, so adding a rule pattern without listing its type fails
    here rather than silently leaving the other consumer behind.

    The two are supersets, not equals: `ContactList` is a vocabulary entry
    with no rule, because the ratchet greps source text including prose and
    would fire on comments that merely name a frontend screen.
    """
    vocabulary = set(config.get("retired_boundary_vocabulary", []))
    missing = {}
    for rule, definition in config.get("boundary_rules", {}).items():
        absent = _pattern_type_names(definition.get("patterns", [])) - vocabulary
        if absent:
            missing[rule] = sorted(absent)

    if missing:
        detail = "; ".join(f"{rule}: {', '.join(names)}" for rule, names in sorted(missing.items()))
        raise VocabularyDriftError(
            f"boundary rules grep for types absent from retired_boundary_vocabulary — {detail}"
        )


def load_config(config_path: Path) -> dict:
    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)
    validate_vocabulary_coverage(config)
    return config


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


def scan_file(
    path: Path,
    rules: dict[str, dict],
    lookback: int,
    lookahead: int,
    ignore_exceptions: bool,
) -> dict[str, list[tuple[int, str]]]:
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
            allow_exceptions = rules[name].get("allow_exceptions", True)
            if allow_exceptions and not ignore_exceptions and has_humble_exception(
                lines, idx, lookback, lookahead
            ):
                continue
            findings[name].append((idx + 1, line.strip()))
    return findings


def rule_message(rules: dict[str, dict], name: str) -> str:
    return rules[name].get("message", name)


def repo_rules(config: dict, repo: str) -> dict[str, dict]:
    rules = dict(config.get("boundary_rules", {}))
    rules.update(config["repos"][repo]["rules"])
    return rules


def resolve_source_root(repo_path: Path, repo: str, rel: str) -> Path:
    parts = Path(rel).parts
    if parts and parts[0] == repo:
        parts = parts[1:]
    return repo_path.joinpath(*parts)


def scan_repo(
    workspace_root: Path,
    repo: str,
    repo_path: Path | None,
    config: dict,
    lookback: int,
    lookahead: int,
    ignore_exceptions: bool = False,
) -> dict:
    repo_config = config["repos"][repo]
    source_roots = repo_config["source_roots"]
    extensions = set(repo_config.get("extensions", []))
    exclude_dirs = set(repo_config.get("exclude_dirs", []))
    rules = repo_rules(config, repo)

    counts = {name: 0 for name in rules}
    examples: dict[str, list[tuple[str, int, str]]] = {name: [] for name in rules}
    missing_roots = []

    for rel in source_roots:
        if repo_path is not None:
            root = resolve_source_root(repo_path, repo, rel)
        else:
            root = workspace_root / rel
        if not root.exists():
            missing_roots.append(str(root))
            continue
        for file in find_files(root, extensions, exclude_dirs):
            display = file.relative_to(repo_path or workspace_root)
            findings = scan_file(file, rules, lookback, lookahead, ignore_exceptions)
            for name, matches in findings.items():
                counts[name] += len(matches)
                for line_no, line_text in matches:
                    if len(examples[name]) < 5:
                        examples[name].append((str(display), line_no, line_text))
    return {
        "counts": counts,
        "examples": examples,
        "rules": rules,
        "missing_roots": missing_roots,
    }


def scan_retired_boundary(result: dict, workspace_root: Path, repo_path: Path | None, repo_config: dict) -> None:
    """Add a deterministic aggregate count for retired boundary symbols."""
    total = 0
    roots = repo_config["source_roots"]
    extensions = set(repo_config.get("extensions", []))
    excludes = set(repo_config.get("exclude_dirs", []))
    examples = []
    for rel in roots:
        root = (repo_path or workspace_root) / rel
        for file in find_files(root, extensions, excludes):
            try:
                lines = file.read_text(encoding="utf-8", errors="ignore").splitlines()
            except OSError:
                continue
            for line_no, line in enumerate(lines, 1):
                hits = sum(bool(pattern.search(line)) for pattern in RETIRED_BOUNDARY_PATTERNS)
                total += hits
                if hits and len(examples) < 5:
                    examples.append((str(file.relative_to(repo_path or workspace_root)), line_no, line.strip()))
    result["counts"]["retired_boundary_types"] = total
    result["examples"]["retired_boundary_types"] = examples
    result["rules"]["retired_boundary_types"] = {
        "message": "Frontend must expose only Event -> Core -> Command[]; remove retired ScreenModel/UserAction/ActionResult and split dispatch APIs.",
        "patterns": [pattern.pattern for pattern in RETIRED_BOUNDARY_PATTERNS],
    }


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


def check_source_roots(repo: str, result: dict) -> int:
    if not result["missing_roots"]:
        return 0
    print(
        f"humble_check ({repo}): configured source roots are missing; refusing a zero-file pass",
        file=sys.stderr,
    )
    for root in result["missing_roots"]:
        print(f"  {root}", file=sys.stderr)
    return 2


def validate_baseline_transition(current: dict, previous: dict) -> int:
    if (
        previous.get("schema_version", 1) < 2
        and current.get("schema_version") == 2
    ):
        print(
            "humble_check: accepted one-time schema-2 baseline for corrected source-root scanning"
        )
        return 0

    regressions = []
    for repo, previous_rules in previous.get("repos", {}).items():
        current_rules = current.get("repos", {}).get(repo)
        if current_rules is None:
            regressions.append((repo, "*", "removed", "repo"))
            continue
        for name, previous_count in previous_rules.items():
            if name not in current_rules:
                regressions.append((repo, name, "removed", previous_count))
            elif current_rules[name] > previous_count:
                regressions.append(
                    (repo, name, current_rules[name], previous_count)
                )

    if not regressions:
        print("humble_check: baseline transition only adds rules or decreases counts")
        return 0

    print(
        "humble_check: baseline transition increased or removed protected counters",
        file=sys.stderr,
    )
    for repo, name, current_value, previous_value in regressions:
        print(
            f"  {repo}.{name}: previous={previous_value}, current={current_value}",
            file=sys.stderr,
        )
    return 1


def check_release_zero(
    workspace_root: Path,
    config: dict,
    baseline: dict,
    lookback: int,
    lookahead: int,
) -> int:
    failures = 0
    for repo in config["repos"]:
        result = scan_repo(
            workspace_root,
            repo,
            None,
            config,
            lookback,
            lookahead,
            ignore_exceptions=True,
        )
        if check_source_roots(repo, result):
            failures += 1
            continue

        repo_baseline = baseline.get("repos", {}).get(repo, {})
        for name, count in result["counts"].items():
            baseline_count = repo_baseline.get(name, 0)
            if count == 0 and baseline_count == 0:
                continue
            failures += 1
            print(
                f"  {repo}.{name}: live={count}, baseline={baseline_count}",
                file=sys.stderr,
            )

    if failures:
        print(
            f"humble_check: release blocked by {failures} nonzero presentation-boundary counters",
            file=sys.stderr,
        )
        return 1

    print("humble_check: release-zero gate passed")
    return 0


def tighten_baseline(
    workspace_root: Path,
    config: dict,
    baseline: dict,
    baseline_path: Path,
    lookback: int,
    lookahead: int,
    only_repo: str | None = None,
) -> int:
    """Lower stored counters to their measured value.

    Without this the baseline only ever records the high-water mark: counts
    fall as violations are retired, the stored numbers do not follow, and the
    accumulated slack silently forgives future regressions. A counter that is
    *above* its baseline is left alone — absorbing a regression is the one
    thing a ratchet may never do, and `--check` exists to report it.

    `only_repo` narrows the sweep to one repo; without it every configured
    repo must be present, since a missing checkout measures zero.
    """
    lowered = []
    repos = [only_repo] if only_repo else sorted(config["repos"])
    for repo in repos:
        result = scan_repo(workspace_root, repo, None, config, lookback, lookahead)
        if check_source_roots(repo, result):
            print(
                "humble_check: refusing to tighten from an incomplete checkout — "
                "an unscanned repo measures zero and would zero its baseline",
                file=sys.stderr,
            )
            return 2

        repo_baseline = baseline.setdefault("repos", {}).setdefault(repo, {})
        for name, count in result["counts"].items():
            stored = repo_baseline.get(name)
            if stored is None or count >= stored:
                continue
            repo_baseline[name] = count
            lowered.append((repo, name, stored, count))

    if not lowered:
        print("humble_check: baselines already match measured counts")
        return 0

    baseline_path.write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")
    for repo, name, stored, count in lowered:
        print(f"  {repo}.{name}: {stored} -> {count}")
    print(f"humble_check: lowered {len(lowered)} counter(s) to measured counts")
    return 0


def check_zero(repo: str, result: dict) -> int:
    """Release gate: every measured boundary-violation counter must be zero."""
    nonzero = [(name, count) for name, count in result["counts"].items() if count]
    if not nonzero:
        print(f"humble_check ({repo}): OK — all boundary counters are zero")
        return 0
    print(f"humble_check ({repo}): {len(nonzero)} counter(s) are not zero", file=sys.stderr)
    for name, count in nonzero:
        print(f"  [{name}] current {count}: {rule_message(result['rules'], name)}", file=sys.stderr)
    print("Release blocked: retire all frontend boundary violations before publishing.", file=sys.stderr)
    return 1


def run(
    workspace_root: Path,
    repo: str,
    repo_path: Path | None,
    config: dict,
    lookback: int,
    lookahead: int,
    baseline: dict | None,
    require_zero: bool = False,
) -> int:
    if repo not in config["repos"]:
        print(f"humble_check: no rules configured for repo '{repo}'", file=sys.stderr)
        return 2

    result = scan_repo(workspace_root, repo, repo_path, config, lookback, lookahead)
    if repo_path is not None and check_source_roots(repo, result):
        return 2
    if require_zero:
        scan_retired_boundary(result, workspace_root, repo_path, config["repos"][repo])
        return check_zero(repo, result)
    if baseline is None:
        print(emit_snapshot(repo, result))
        return 0
    return check_baseline(repo, result, baseline)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Cross-language Humble UI ratchet")
    parser.add_argument("--repo", help="Frontend repo name (e.g. ios, android)")
    parser.add_argument("--workspace-root", type=Path, help="Workspace root containing all repos")
    parser.add_argument("--repo-path", type=Path, help="Path to the repo itself (overrides workspace-root)")
    parser.add_argument("--config", type=Path, help="Path to humble_check_rules.json")
    parser.add_argument("--check", type=Path, metavar="BASELINE", help="Baseline JSON to ratchet against")
    parser.add_argument(
        "--validate-baseline",
        type=Path,
        metavar="CURRENT",
        help="Validate that a baseline only adds rules or decreases existing counters",
    )
    parser.add_argument(
        "--against",
        type=Path,
        metavar="PREVIOUS",
        help="Previous baseline for --validate-baseline",
    )
    parser.add_argument(
        "--release-zero",
        action="store_true",
        help="Require every configured live and baseline counter to be zero",
    )
    parser.add_argument("--require-zero", action="store_true", help="Release gate: require every measured counter to be zero")
    parser.add_argument("--tighten", type=Path, metavar="BASELINE", help="Lower stored counters to measured counts; never raises one")
    parser.add_argument("--lookback", type=int, default=DEFAULT_LOOKBACK, help="Lines before a match to search for TODO(HUMBLE)")
    parser.add_argument("--lookahead", type=int, default=DEFAULT_LOOKAHEAD, help="Lines after a match to search for TODO(HUMBLE)")
    args = parser.parse_args(argv)

    script_dir = Path(__file__).resolve().parent
    workspace_root = args.workspace_root or (script_dir.parent.parent)
    config_path = args.config or (script_dir / "humble_check_rules.json")

    if not config_path.exists():
        print(f"humble_check: config not found: {config_path}", file=sys.stderr)
        return 2

    if args.validate_baseline:
        if not args.against:
            parser.error("--validate-baseline requires --against")
        if not args.validate_baseline.exists() or not args.against.exists():
            print("humble_check: baseline transition file not found", file=sys.stderr)
            return 2
        return validate_baseline_transition(
            load_baseline(args.validate_baseline),
            load_baseline(args.against),
        )

    baseline = None
    if args.check:
        if not args.check.exists():
            print(f"humble_check: baseline not found: {args.check}", file=sys.stderr)
            return 2
        baseline = load_baseline(args.check)

    config = load_config(config_path)

    if args.tighten:
        if not args.tighten.exists():
            print(f"humble_check: baseline not found: {args.tighten}", file=sys.stderr)
            return 2
        return tighten_baseline(
            workspace_root,
            config,
            load_baseline(args.tighten),
            args.tighten,
            args.lookback,
            args.lookahead,
            args.repo,
        )

    if args.release_zero:
        if baseline is None:
            parser.error("--release-zero requires --check BASELINE")
        return check_release_zero(
            workspace_root,
            config,
            baseline,
            args.lookback,
            args.lookahead,
        )
    if not args.repo:
        parser.error("--repo is required unless a standalone validation mode is used")
    return run(workspace_root, args.repo, args.repo_path, config, args.lookback, args.lookahead, baseline, args.require_zero)


if __name__ == "__main__":
    sys.exit(main())
