#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# hooks/lib/md-lint.sh is the pre-push markdown gate. When every changed
# file is excluded by .markdownlintignore, markdownlint gets no files, prints
# its usage text and exits 0 — the gate used to report that as "Markdown lint
# OK" (vauchi/private#60). Pin: real findings fail, an all-ignored push says
# nothing was linted, and a clean push passes.

set -uo pipefail

if ! command -v markdownlint >/dev/null 2>&1; then
    echo "md-lint: markdownlint not installed — skipped"
    exit 0
fi

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LINT="$DIR/hooks/lib/md-lint.sh"
PASS=0
FAIL=0

check() {
    local name="$1" expected_rc="$2" expected_text="$3" rc="$4" out="$5"
    if [[ "$rc" == "$expected_rc" && "$out" == *"$expected_text"* ]]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (rc=%s, want %s; output: %s)\n' "$name" "$rc" "$expected_rc" "$out"
        FAIL=$((FAIL + 1))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/docs" "$REPO/.claude/docs"
git init --quiet "$REPO"
printf '{ "MD013": { "line_length": 80 } }\n' > "$REPO/.markdownlint.json"
printf '.claude/**/*.md\n' > "$REPO/.markdownlintignore"
LONG="# T

$(printf 'word %.0s' $(seq 1 30))
"
printf '%s' "$LONG" > "$REPO/docs/bad.md"
printf '%s' "$LONG" > "$REPO/.claude/docs/bad.md"
printf '# T\n\nShort.\n' > "$REPO/docs/good.md"

out=$(printf 'docs/bad.md\n' | bash "$LINT" "$REPO" 2>&1); rc=$?
check "a finding fails the gate" 1 "FAILED" "$rc" "$out"

out=$(printf '.claude/docs/bad.md\n' | bash "$LINT" "$REPO" 2>&1); rc=$?
check "an all-ignored push says nothing was linted" 0 "nothing linted" "$rc" "$out"
if [[ "$out" == *"Usage: markdownlint"* || "$out" == *"Markdown lint OK"* ]]; then
    printf '  FAIL  all-ignored push must not dump usage or claim OK: %s\n' "$out"
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi

out=$(printf 'docs/good.md\n' | bash "$LINT" "$REPO" 2>&1); rc=$?
check "a clean push passes" 0 "Markdown lint OK" "$rc" "$out"

printf '\nmd-lint: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
