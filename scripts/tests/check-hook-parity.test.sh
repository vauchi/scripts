#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Test runner for `scripts/scripts/check-hook-parity.sh`.
#
# The detector reports hooks present in one harness's hook dir but not the
# other (the silent-divergence case: a guardrail added to .claude only).
# This test builds synthetic .claude/hooks and .kimi-code/hooks trees.
#
# Run: bash scripts/scripts/tests/check-hook-parity.test.sh

set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/check-hook-parity.sh"
WORK="/tmp/hook-parity.test.$$"

if [[ ! -x "$SCRIPT" ]]; then
    echo "FATAL: $SCRIPT not executable (not implemented — RED)" >&2
    exit 1
fi

PASS=0
FAIL=0
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.claude/hooks" "$WORK/.kimi-code/hooks"

ck() { # name, condition
    if [[ "$2" == "0" ]]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS+1))
    else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); fi
}

# ── In sync: same hook set → exit 0, "same hook set" message ──
: > "$WORK/.claude/hooks/a.sh"; : > "$WORK/.kimi-code/hooks/a.sh"
out=$(bash "$SCRIPT" "$WORK"); code=$?
ck "in-sync exits 0" "$([[ $code -eq 0 ]] && echo 0 || echo 1)"
ck "in-sync reports parity" "$(echo "$out" | grep -q 'same hook set' && echo 0 || echo 1)"

# ── Claude-only hook (the silent-drift case) is reported ──
: > "$WORK/.claude/hooks/new-guard.sh"
out=$(bash "$SCRIPT" "$WORK"); code=$?
ck "claude-only hook listed" "$(echo "$out" | grep -q '+ new-guard.sh' && echo 0 || echo 1)"
ck "non-strict still exits 0" "$([[ $code -eq 0 ]] && echo 0 || echo 1)"

# ── --strict exits 1 on drift ──
bash "$SCRIPT" --strict "$WORK" >/dev/null 2>&1; code=$?
ck "strict exits 1 on drift" "$([[ $code -eq 1 ]] && echo 0 || echo 1)"

# ── Kimi-only hook reported with '-' marker ──
: > "$WORK/.kimi-code/hooks/kimi-extra.sh"
out=$(bash "$SCRIPT" "$WORK")
ck "kimi-only hook listed" "$(echo "$out" | grep -q '\- kimi-extra.sh' && echo 0 || echo 1)"

# ── tests/ subdir ignored (only top-level *.sh compared) ──
mkdir -p "$WORK/.claude/hooks/tests"; : > "$WORK/.claude/hooks/tests/a.test.sh"
out=$(bash "$SCRIPT" "$WORK")
ck "tests/ subdir not treated as a hook" "$(echo "$out" | grep -q 'a.test.sh' && echo 1 || echo 0)"

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    printf 'check-hook-parity.test: %d passed, 0 failed\n' "$PASS"; exit 0
else
    printf 'check-hook-parity.test: %d passed, %d FAILED\n' "$PASS" "$FAIL"; exit 1
fi
