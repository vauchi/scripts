#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

"""VCI06: a hard `needs:` on a job a merge-request diff can leave out.

GitLab rejects a whole merge-request pipeline, with zero jobs and no
retry, when a job is in it but a job it hard-needs is not (ios!699:
`screenshots:store` needs `build:debug`, whose `changes:` rules skipped a
`.swiftformat`-only diff). Push-time CI lint passes because it does not
evaluate merge-request `changes:` (vauchi/private#490).

Input: a resolved CI config (includes merged, e.g. the `merged_yaml` of
GitLab's CI lint API). `extends:` and `!reference` are resolved here.
For every non-optional same-pipeline need, the needing job's rules are
evaluated in a merge-request context against sample changed paths drawn
from both jobs' `changes:` globs plus an unrelated file; a path for which
the needing job runs and the needed job does not is a violation.

Usage: check-ci-needs-rules.py <resolved.yml> [...]
Rule page: _private/docs/lint-errors/vci06-needs-on-skippable-job.md
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

RESERVED = {
    "stages", "variables", "default", "include", "workflow", "image", "services",
    "before_script", "after_script", "cache", "spec",
}

MR_CONTEXT = {
    "CI_PIPELINE_SOURCE": "merge_request_event",
    "CI_MERGE_REQUEST_IID": "1",
    "CI_MERGE_REQUEST_ID": "1",
    "CI_MERGE_REQUEST_EVENT_TYPE": "detached",
    "CI_MERGE_REQUEST_TARGET_BRANCH_NAME": "main",
    "CI_MERGE_REQUEST_SOURCE_BRANCH_NAME": "feature",
    "CI_DEFAULT_BRANCH": "main",
    "CI_COMMIT_REF_NAME": "feature",
    "CI_PROJECT_NAMESPACE": "vauchi",
}

UNRELATED_PATH = "an-unrelated-file.txt"


class Reference(list):
    """A `!reference [job, key, ...]` left for resolution."""


def _reference(loader: yaml.SafeLoader, node: yaml.Node) -> Reference:
    return Reference(loader.construct_sequence(node))


class Loader(yaml.SafeLoader):
    pass


Loader.add_constructor("!reference", _reference)


def load(path: Path) -> dict:
    return yaml.load(path.read_text(encoding="utf-8"), Loader=Loader) or {}


def resolve_reference(config: dict, ref: Reference):
    value = config
    for key in ref:
        value = value.get(key) if isinstance(value, dict) else None
    return value


def deep_merge(base, over):
    if isinstance(base, dict) and isinstance(over, dict):
        merged = dict(base)
        for key, value in over.items():
            merged[key] = deep_merge(base.get(key), value) if key in base else value
        return merged
    return over


def resolve_job(config: dict, name: str, seen: frozenset = frozenset()) -> dict:
    job = config.get(name) or {}
    parents = job.get("extends") or []
    if isinstance(parents, str):
        parents = [parents]
    merged: dict = {}
    for parent in parents:
        if parent in seen:
            continue
        merged = deep_merge(merged, resolve_job(config, parent, seen | {name}))
    own = {k: v for k, v in job.items() if k != "extends"}
    return deep_merge(merged, own)


def flatten_rules(config: dict, rules) -> list:
    out = []
    for rule in rules or []:
        if isinstance(rule, Reference):
            out.extend(flatten_rules(config, resolve_reference(config, rule)))
        elif isinstance(rule, list):
            out.extend(flatten_rules(config, rule))
        elif isinstance(rule, dict):
            out.append(rule)
    return out


# ── `if:` expressions ────────────────────────────────────────────────

TOKEN = re.compile(r"""\s*(?:
    (?P<var>\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)
  | (?P<str>"[^"]*"|'[^']*')
  | (?P<re>/(?:\\.|[^/])*/[a-z]*)
  | (?P<op>==|!=|=~|!~|&&|\|\||\(|\))
  | (?P<null>null)
)""", re.X)


class Expr:
    def __init__(self, text: str, variables: dict):
        self.tokens = []
        pos = 0
        text = text.strip()
        while pos < len(text):
            match = TOKEN.match(text, pos)
            if not match or match.end() == pos:
                raise ValueError(f"cannot parse rule condition: {text!r}")
            kind = match.lastgroup
            self.tokens.append((kind, match.group(kind)))
            pos = match.end()
        self.variables = variables
        self.i = 0

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else (None, None)

    def take(self):
        token = self.peek()
        self.i += 1
        return token

    def evaluate(self) -> bool:
        value = self.or_expr()
        return bool(value)

    def or_expr(self):
        value = self.and_expr()
        while self.peek() == ("op", "||"):
            self.take()
            right = self.and_expr()
            value = bool(value) or bool(right)
        return value

    def and_expr(self):
        value = self.comparison()
        while self.peek() == ("op", "&&"):
            self.take()
            right = self.comparison()
            value = bool(value) and bool(right)
        return value

    def comparison(self):
        left = self.operand()
        kind, op = self.peek()
        if kind == "op" and op in ("==", "!=", "=~", "!~"):
            self.take()
            right = self.operand()
            if op == "==":
                return left == right
            if op == "!=":
                return left != right
            matched = bool(left is not None and isinstance(right, re.Pattern) and right.search(left))
            return matched if op == "=~" else not matched
        return left

    def operand(self):
        kind, text = self.take()
        if kind == "op" and text == "(":
            value = self.or_expr()
            self.take()
            return value
        if kind == "var":
            name = text.strip("${}")
            value = self.variables.get(name)
            return value if value not in ("",) else None
        if kind == "str":
            return text[1:-1]
        if kind == "null":
            return None
        if kind == "re":
            body, _, flags = text[1:].rpartition("/")
            return re.compile(body, re.I if "i" in flags else 0)
        raise ValueError(f"unexpected token {text!r}")


# ── `changes:` globs (Ruby File.fnmatch with PATHNAME|DOTMATCH|EXTGLOB) ──

def glob_regex(pattern: str) -> re.Pattern:
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append(r"(?:.*/)?"); i += 3
        elif pattern.startswith("**", i):
            out.append(r".*"); i += 2
        elif pattern[i] == "*":
            out.append(r"[^/]*"); i += 1
        elif pattern[i] == "?":
            out.append(r"[^/]"); i += 1
        elif pattern[i] == "{":
            close = pattern.find("}", i)
            if close == -1:
                out.append(re.escape(pattern[i])); i += 1
                continue
            options = pattern[i + 1:close].split(",")
            out.append("(?:" + "|".join(re.escape(o) for o in options) + ")"); i = close + 1
        else:
            out.append(re.escape(pattern[i])); i += 1
    return re.compile("^" + "".join(out) + "$")


def sample_path(pattern: str) -> str:
    path = re.sub(r"\{([^,}]*)[^}]*\}", r"\1", pattern)
    path = path.replace("**/", "").replace("**", "x").replace("*", "x").replace("?", "x")
    return path or "x"


def changes_of(rule: dict) -> list[str] | None:
    changes = rule.get("changes")
    if changes is None:
        return None
    if isinstance(changes, dict):
        changes = changes.get("paths") or []
    return [c for c in changes if isinstance(c, str)]


# ── inclusion in a merge-request pipeline ────────────────────────────

def included(job: dict, rules: list, path: str, variables: dict) -> bool:
    if not rules:
        only = job.get("only")
        if isinstance(only, list):
            return "merge_requests" in only
        if isinstance(only, dict):
            refs = only.get("refs") or []
            return not refs or "merge_requests" in refs
        return "rules" not in job or job.get("rules") == []
    for rule in rules:
        condition = rule.get("if")
        if condition is not None and not Expr(str(condition), variables).evaluate():
            continue
        globs = changes_of(rule)
        if globs is not None and not any(glob_regex(g).match(path) for g in globs):
            continue
        return rule.get("when", "on_success") != "never"
    return False


def hard_needs(job: dict) -> list[str]:
    names = []
    for need in job.get("needs") or []:
        if isinstance(need, str):
            names.append(need)
        elif isinstance(need, dict) and "job" in need:
            if need.get("optional") or "pipeline" in need or "project" in need:
                continue
            names.append(need["job"])
    return names


def check(config: dict, source: str) -> list[str]:
    variables = dict(MR_CONTEXT)
    for key, value in (config.get("variables") or {}).items():
        if isinstance(value, (str, int, float)):
            variables[key] = str(value)
        elif isinstance(value, dict) and "value" in value:
            variables[key] = str(value["value"])
    names = [n for n, v in config.items()
             if n not in RESERVED and not n.startswith(".") and isinstance(v, dict)]
    resolved = {n: resolve_job(config, n) for n in names}
    rules = {n: flatten_rules(config, j.get("rules")) for n, j in resolved.items()}
    violations = []
    for name, job in resolved.items():
        for needed in hard_needs(job):
            if needed not in resolved:
                continue
            globs = [g for r in rules[name] + rules[needed] for g in (changes_of(r) or [])]
            for path in [UNRELATED_PATH] + [sample_path(g) for g in globs]:
                if included(job, rules[name], path, variables) and not included(
                        resolved[needed], rules[needed], path, variables):
                    violations.append(
                        f"  {source}: VCI06: job \"{name}\" needs \"{needed}\", but a merge request "
                        f"changing only {path} runs \"{name}\" without \"{needed}\" and GitLab rejects "
                        f"the whole pipeline — fix: give \"{name}\" the merge-request changes: of "
                        f"\"{needed}\", or mark the need optional: true. "
                        f"[_private/docs/lint-errors/vci06-needs-on-skippable-job.md]")
                    break
    return violations


def main(argv: list[str]) -> int:
    if not argv:
        print("Usage: check-ci-needs-rules.py <resolved.yml> [...]", file=sys.stderr)
        return 2
    violations = []
    for name in argv:
        violations += check(load(Path(name)), name)
    for line in violations:
        print(line)
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
