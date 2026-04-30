#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck disable=SC2016
# Reason: every test fixture in this file uses single-quoted strings
# containing literal backticks (markdown code-span syntax). Shellcheck
# warns that "expressions don't expand in single quotes" on every
# fixture line — but the literal `@word` syntax is the entire point of
# the test. The escaper's contract is that a code-span boundary is
# preserved verbatim, so the input MUST remain literal. Same precedent
# as scripts/tests/check-binding-abi.test.sh:30.

# escape-mr-mentions.test.sh — Regression suite for the markdown-aware
# `@mention` escaper used by `just gitlab mr-create`.
#
# Origin: vauchi/ios!370 — the previous naive sed escaper double-wrapped
# `@word` references that already lived inside a code span, producing
# broken nesting that GitLab parsed as a bare mention. This test pins
# the corrected behaviour.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../escape-mr-mentions.py"

pass=0
fail=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n    want: %q\n    got:  %q\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

run() {
    printf '%s' "$1" | "$SCRIPT"
}

# ── Bare @word gets wrapped ───────────────────────────────────
assert_eq "bare @word wrapped" \
    'Mention `@duress` here.' \
    "$(run 'Mention @duress here.')"

# ── Already-wrapped @word preserved (single-token span) ───────
assert_eq "single-token already escaped preserved" \
    'Already `@JvmStatic` escaped.' \
    "$(run 'Already `@JvmStatic` escaped.')"

# ── @word inside a multi-token span NOT double-wrapped ────────
# This is the vauchi/ios!370 regression case.
assert_eq "multi-token span @Published preserved" \
    'Drop `@Published var deviceLinkState`.' \
    "$(run 'Drop `@Published var deviceLinkState`.')"

assert_eq "two adjacent multi-token spans" \
    'Drop `@Published var x`, `@Published var y`.' \
    "$(run 'Drop `@Published var x`, `@Published var y`.')"

# ── Email left alone ──────────────────────────────────────────
assert_eq "email is not a mention" \
    'noreply@anthropic.com' \
    "$(run 'noreply@anthropic.com')"

# ── Mixed content ─────────────────────────────────────────────
assert_eq "mixed escaped + bare + email" \
    'See `@Published` and `@Sendable`, ping noreply@anthropic.com.' \
    "$(run 'See `@Published` and @Sendable, ping noreply@anthropic.com.')"

# ── --check mode catches surviving bare mentions ──────────────
if echo 'Bare @duress survived' | "$SCRIPT" --check 2>/dev/null; then
    printf '  FAIL --check missed bare mention\n' >&2
    fail=$((fail + 1))
else
    printf '  PASS --check catches bare mention\n'
    pass=$((pass + 1))
fi

if echo 'Escaped `@duress` only' | "$SCRIPT" --check 2>/dev/null; then
    printf '  PASS --check accepts escaped mention\n'
    pass=$((pass + 1))
else
    printf '  FAIL --check false-positive on escaped mention\n' >&2
    fail=$((fail + 1))
fi

if echo 'noreply@anthropic.com only' | "$SCRIPT" --check 2>/dev/null; then
    printf '  PASS --check accepts plain email\n'
    pass=$((pass + 1))
else
    printf '  FAIL --check false-positive on email\n' >&2
    fail=$((fail + 1))
fi

# ── Idempotence: escape twice == escape once ──────────────────
src='Mix of @bare and `@escaped` and `@inside multi`.'
once=$(printf '%s' "$src" | "$SCRIPT")
twice=$(printf '%s' "$once" | "$SCRIPT")
assert_eq "idempotent (escape twice equals once)" "$once" "$twice"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
