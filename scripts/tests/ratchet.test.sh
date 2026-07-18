#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/ratchet.sh — the generic positive-gate primitive:
# seed, regress (fail), improve (advisory vs --tighten), equal; up + down; floats.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/ratchet.sh"

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
has() { printf '%s' "$2" | grep -q "$1" && echo 1 || echo 0; }
base_of() { grep -vE '^[[:space:]]*(#|$)' "$1" | head -1 | tr -d '[:space:]'; }
run() { out="$("$SCRIPT" "$@" 2>&1)"; rc=$?; }

# ── seed on first run (no baseline file) ──────────────────────────────
D="$(mktemp -d)"; B="$D/base"
run --baseline "$B" --direction down --current 7
assert_eq "seed: exit 0" "0" "$rc"
assert_eq "seed: writes current" "7" "$(base_of "$B")"
rm -rf "$D"

# ── down (budget): regression fails ───────────────────────────────────
D="$(mktemp -d)"; B="$D/base"; printf '10\n' > "$B"
run --baseline "$B" --direction down --current 15 --label bugs
assert_eq "down regress: exit 1" "1" "$rc"
assert_eq "down regress: says regressed" "1" "$(has regressed "$out")"
assert_eq "down regress: baseline untouched" "10" "$(base_of "$B")"
rm -rf "$D"

# ── down improve, check mode: passes, baseline NOT written ────────────
D="$(mktemp -d)"; B="$D/base"; printf '10\n' > "$B"
run --baseline "$B" --direction down --current 5
assert_eq "down improve check: exit 0" "0" "$rc"
assert_eq "down improve check: advises" "1" "$(has improved "$out")"
assert_eq "down improve check: baseline unchanged" "10" "$(base_of "$B")"
rm -rf "$D"

# ── down improve, --tighten: baseline rewritten ───────────────────────
D="$(mktemp -d)"; B="$D/base"; printf '10\n' > "$B"
run --baseline "$B" --direction down --current 5 --tighten
assert_eq "down tighten: exit 0" "0" "$rc"
assert_eq "down tighten: baseline lowered" "5" "$(base_of "$B")"
rm -rf "$D"

# ── up (climb), float regression fails ────────────────────────────────
D="$(mktemp -d)"; B="$D/base"; printf '89.5\n' > "$B"
run --baseline "$B" --direction up --current 89.34 --label coverage
assert_eq "up regress float: exit 1" "1" "$rc"
rm -rf "$D"

# ── up improve, --tighten, float: baseline raised ─────────────────────
D="$(mktemp -d)"; B="$D/base"; printf '90\n' > "$B"
run --baseline "$B" --direction up --current 95.2 --tighten
assert_eq "up tighten float: exit 0" "0" "$rc"
assert_eq "up tighten float: baseline raised" "95.2" "$(base_of "$B")"
rm -rf "$D"

# ── equal: passes, no change ──────────────────────────────────────────
D="$(mktemp -d)"; B="$D/base"; printf '10\n' > "$B"
run --baseline "$B" --direction down --current 10
assert_eq "equal: exit 0" "0" "$rc"
assert_eq "equal: at baseline" "1" "$(has 'at baseline' "$out")"
rm -rf "$D"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
