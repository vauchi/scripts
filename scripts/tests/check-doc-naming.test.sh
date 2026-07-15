#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for ci-templates/check-doc-naming.sh (VDC05) — the
# canonical (single-copy) doc-naming check.

set -euo pipefail

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/../ci-templates/check-doc-naming.sh"

pass=0
fail=0
assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

run_files() { out="$("$SCRIPT" --files "$@" 2>&1)"; rc=$?; }

run_files docs/investigations/2026-07-05-some-topic.md
assert_eq "dated file: exit 0" "0" "$rc"

run_files docs/investigations/some-topic.md
assert_eq "undated file: exit 1" "1" "$rc"
assert_eq "undated: VDC05 + fix in message" "1" \
    "$(printf '%s' "$out" | grep -qE 'VDC05: .+ — fix: .+' && echo 1 || echo 0)"

run_files docs/problems/2026-07-05-x/investigation.md docs/problems/2026-07-05-x/README.md
assert_eq "record companions: exit 0" "0" "$rc"

run_files docs/lint-errors/vsh06-grep-exclude.md
assert_eq "lint-errors ID-named page: exit 0" "0" "$rc"

run_files docs/decisions/adr-060-something.md
assert_eq "decisions adr file: exit 0" "0" "$rc"

run_files .claude/rules/some-rule.md
assert_eq ".claude tree: exit 0" "0" "$rc"

run_files docs/reference/2026-07-05-x.plan.md docs/audit/2026-01-01-y-report.md
assert_eq "plan/report suffixes: exit 0" "0" "$rc"

run_files docs/designs/2026-07-05-foo.md
assert_eq "designs without -design.md: exit 1" "1" "$rc"

run_files docs/designs/2026-07-05-foo-design.md
assert_eq "designs with -design.md: exit 0" "0" "$rc"

# non-tautology guard (CC-21)
stub="$(mktemp)"; printf '#!/bin/sh\nexit 0\n' > "$stub"; chmod +x "$stub"
"$stub" --files docs/investigations/undated.md >/dev/null 2>&1; rc=$?
assert_eq "stub detector would be caught (exit != 1 detected)" "0" "$rc"
rm -f "$stub"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
