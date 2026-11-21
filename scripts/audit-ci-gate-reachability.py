#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
"""Enumerate CI jobs whose green cannot mean a merge request is safe.

Two deterministic mechanisms:
  M1a  allow_failure: true
  M1b  rules that never match an MR pipeline

Reports only, and reports candidates rather than defects. Both mechanisms
are legitimate choices — packaging, release verification and
baseline-recording jobs are post-merge by design, and an advisory lint
may be advisory on purpose. Whether a candidate is a *defect* depends on
whether anyone reads that job's green as a gate, which no scan settles.
On 2026-08-09 six of the six category-B candidates were read by hand and
five were correct by design.

WHAT THIS CANNOT FIND, and why that matters more than the counts: a gate
can be vacuous without any syntactic marker. An assertion comparing an
interpolated value against itself, a mock returning the value under test,
a fixture that regenerates its own expectation, or a flow file nothing
invokes are all invisible here — the last is an *absence*, and no grep
finds a call that was never written. The instance that motivated this
script (a duress PIN set to the literal string "undefined" on a real
device) was in that class. Treat a clean run as "these mechanisms are
accounted for", never as "the gates are sound".

Background and the full instance list:
`_private/docs/backlog/2026-08-09-gates-that-pass-by-not-running.md`

GitLab CI YAML is regular enough to parse by indentation; pyyaml is not
installed here and the shapes needed (top-level job keys, their `rules:`
and `allow_failure:`) do not require a full parser.

Usage:
  audit-ci-gate-reachability.py [workspace_root]
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")

files = []
for pat in ("*/.gitlab-ci.yml", "*/ci-templates/*.yml", "*/ci/*.yml",
            ".gitlab-ci.yml", "*/*/ci-templates/*.yml"):
    files.extend(ROOT.glob(pat))
files = sorted({f for f in files if "node_modules" not in str(f)})

JOB = re.compile(r"^([a-zA-Z_][\w:.\-]*):\s*$")
# A job key, not a top-level config key.
NOT_JOBS = {
    "stages", "variables", "default", "include", "workflow", "image",
    "before_script", "after_script", "cache", "services",
}

allow_fail = []
no_mr = []
job_total = 0

for f in files:
    try:
        lines = f.read_text(encoding="utf-8").splitlines()
    except Exception:
        continue
    # Collect each top-level block.
    blocks = {}
    cur, buf = None, []
    for line in lines:
        m = JOB.match(line)
        if m:
            if cur:
                blocks[cur] = buf
            cur, buf = m.group(1), []
        elif cur is not None:
            if line and not line[0].isspace() and not line.startswith("#"):
                blocks[cur] = buf
                cur, buf = None, []
            else:
                buf.append(line)
    if cur:
        blocks[cur] = buf

    for name, body in blocks.items():
        if name in NOT_JOBS or name.startswith("."):
            continue
        text = "\n".join(body)
        if "script" not in text and "trigger" not in text and "extends" not in text:
            continue
        job_total += 1
        rel = str(f.relative_to(ROOT))

        if re.search(r"^\s*allow_failure:\s*true", text, re.M):
            allow_fail.append((rel, name))

        # Does it declare rules/only at all? If not, inherits — skip.
        has_rules = re.search(r"^\s*(rules|only):", text, re.M)
        if has_rules:
            # CI_MERGE_REQUEST_IID is the other way a job opts into MR
            # pipelines. Omitting it made this scan report jobs that do
            # gate MRs — including one with "blocking" in its name.
            mentions_mr = (
                "merge_request_event" in text
                or "merge_requests" in text
                or "CI_MERGE_REQUEST_IID" in text
                or "CI_MERGE_REQUEST_TARGET" in text
                or "CI_MERGE_REQUEST_SOURCE" in text
            )
            if not mentions_mr:
                # Confirm it positively restricts to branch/schedule/tag.
                restricts = re.search(
                    r"CI_COMMIT_BRANCH\s*==\s*\$CI_DEFAULT_BRANCH"
                    r'|CI_PIPELINE_SOURCE\s*==\s*"schedule"'
                    r'|CI_PIPELINE_SOURCE\s*==\s*"web"'
                    r"|CI_COMMIT_TAG",
                    text,
                )
                if restricts:
                    no_mr.append((rel, name))

print(f"CI jobs parsed: {job_total}\n")
print(f"== M1a  allow_failure: true  ({len(allow_fail)}) ==")
for rel, n in allow_fail:
    print(f"  {rel}::{n}")
print(f"\n== M1b  rules never match an MR pipeline  ({len(no_mr)}) ==")
for rel, n in no_mr:
    print(f"  {rel}::{n}")
GATEY = re.compile(r"^(check|lint|test|verify|gates|quality|audit|security|validate)[:.]")
# Jobs whose purpose is to record/refresh a baseline, publish, package or
# fan out are post-merge by design; their green never claimed to gate.
BENIGN = re.compile(r"(:record|^package:|^publish|^trigger:|^deploy|^release|^metrics?:|^cleanup:|^load:|^dast:|^bench:|^resource-group:)")

af = {(r, n) for r, n in allow_fail}
nm = {(r, n) for r, n in no_mr}

cat_a = sorted({(r, n) for r, n in af if GATEY.match(n) and not BENIGN.search(n)})
cat_b = sorted({(r, n) for r, n in nm if GATEY.match(n) and not BENIGN.search(n)} - af)

print(f"\n\n### A. gate-named AND allow_failure:true  ({len(cat_a)})")
print("###    green is advisory; reads as a gate")
for r, n in cat_a:
    print(f"  {r}::{n}")
print(f"\n### B. gate-named, NOT allow_failure, never runs on an MR  ({len(cat_b)})")
print("###    presents as blocking; cannot block a merge request")
for r, n in cat_b:
    print(f"  {r}::{n}")
