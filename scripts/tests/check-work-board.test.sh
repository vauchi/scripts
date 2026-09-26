#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-work-board.sh — VGT05: every In
# Progress item carries a session id + expiry; required sections exist.
# Rule page: _private/docs/lint-errors/vgt05-work-board-claims.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-work-board.sh"

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

run_board() { # $1=content → sets rc, out
    b="$(mktemp)"
    printf '%s\n' "$1" > "$b"
    out="$("$SCRIPT" "$b" 2>&1)"; rc=$?
    rm -f "$b"
}

VALID='# Work Board

## HIGH — Next

- [ ] Some next item with no claim needed

## In Progress

- [ ] Fix relay backoff — record here
  spans multiple lines just fine
  @claude-session-2026-07-05-relay (expires 2026-07-06T22:00Z)

## Done

- [x] Something finished'

run_board "$VALID"
assert_eq "valid board: exit 0" "0" "$rc"

# ── item missing session id ────────────────────────────────────────────
run_board '## In Progress

- [ ] Unclaimed item (expires 2026-07-06T22:00Z)

## Done'
assert_eq "missing session id: exit 1" "1" "$rc"
assert_eq "missing session id: VGT05 in message" "1" \
    "$(printf '%s' "$out" | grep -q 'VGT05:' && echo 1 || echo 0)"
assert_eq "missing session id: names the fix" "1" \
    "$(printf '%s' "$out" | grep -qE 'VGT05: .+ — fix: .+' && echo 1 || echo 0)"

# ── item missing expiry ────────────────────────────────────────────────
run_board '## In Progress

- [ ] Claimed but eternal @claude-session-2026-07-05-x

## Done'
assert_eq "missing expiry: exit 1" "1" "$rc"

# ── malformed expiry date ──────────────────────────────────────────────
run_board '## In Progress

- [ ] Bad expiry @claude-session-2026-07-05-x (expires someday)

## Done'
assert_eq "malformed expiry: exit 1" "1" "$rc"

# ── unclaimed items in Next sections are fine ──────────────────────────
run_board '## HIGH — Next

- [ ] No claim needed here

## In Progress

## Done'
assert_eq "next-section unclaimed: exit 0" "0" "$rc"

# ── missing In Progress section ────────────────────────────────────────
run_board '## HIGH — Next

- [ ] item

## Done'
assert_eq "missing In Progress section: exit 1" "1" "$rc"

# ── missing Done section ───────────────────────────────────────────────
run_board '## In Progress

## HIGH — Next'
assert_eq "missing Done section: exit 1" "1" "$rc"

# ── board moved to issues (ADR-073): nothing left to validate ─────────
run_board '# Work Board — moved to GitLab issues

The queue is the vauchi/private issue tracker.'
assert_eq "board moved to issues: exit 0" "0" "$rc"

# ── non-tautology guard (CC-21) ────────────────────────────────────────
stub="$(mktemp)"; printf '#!/bin/sh\nexit 0\n' > "$stub"; chmod +x "$stub"
b="$(mktemp)"; printf '## In Progress\n\n- [ ] unclaimed\n' > "$b"
"$stub" "$b" >/dev/null 2>&1; rc=$?
assert_eq "stub detector would be caught (exit != 1 detected)" "0" "$rc"
rm -f "$b" "$stub"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
