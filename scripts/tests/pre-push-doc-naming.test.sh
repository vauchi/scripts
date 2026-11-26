#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0

{
    printf 'set -eu\nHOOK_DIR=$1\n'
    printf 'git() { printf "%%s\\n" "$ADDED_DOCS"; return "$DIFF_STATUS"; }\n'
    awk '/^        run_doc_naming_check\(\)/{copy=1} /time_step "Doc naming"/{exit} copy{print}' "$DIR/hooks/pre-push"
    printf 'run_doc_naming_check\n'
} > "$work/runner"

check() {
    local name="$1" expected="$2" docs="$3" diff_status="${4:-0}" hook_dir="${5:-$DIR/hooks}" status
    if ADDED_DOCS="$docs" DIFF_STATUS="$diff_status" bash "$work/runner" "$hook_dir" > "$work/output" 2>&1; then
        status=0
    else
        status=$?
    fi
    if [[ "$status" == "$expected" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL %s: expected %s, got %s\n' "$name" "$expected" "$status" >&2
        cat "$work/output" >&2
    fi
}

check 'problem evidence uses canonical companion exemptions' 0 docs/problems/2026-11-26-example/hardware-executor.md
check 'undated investigations remain rejected' 1 docs/investigations/undated.md
check 'dated designs still require their design suffix' 1 docs/designs/2026-11-26-example.md
check 'properly named designs pass' 0 docs/designs/2026-11-26-example-design.md
check 'all added paths are checked' 1 $'docs/reference/living.md\ndocs/investigations/undated.md'
check 'missing canonical checker fails' 1 docs/investigations/2026-11-26-valid.md 0 "$work/missing/hooks"
check 'failed diff cannot become a clean result' 1 '' 7
check 'no added docs succeeds' 0 ''
printf '%s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
