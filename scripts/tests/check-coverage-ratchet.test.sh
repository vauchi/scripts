#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-coverage-ratchet.sh — parses Cobertura
# line-rate and ratchets coverage upward (VRT01).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-coverage-ratchet.sh"

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
make_report() {
    printf '<?xml version="1.0"?>\n<coverage line-rate="%s" branch-rate="0.5" version="1.0">\n</coverage>\n' \
        "$2" > "$1"
}
run() { out="$("$SCRIPT" "$@" 2>&1)"; rc=$?; }

# ── coverage above baseline (improved): exit 0 ────────────────────────
D="$(mktemp -d)"; make_report "$D/cob.xml" 0.9034; printf '85\n' > "$D/base"
run --report "$D/cob.xml" --baseline "$D/base"
assert_eq "above baseline: exit 0" "0" "$rc"
assert_eq "above baseline: parsed 90.34 as improvement" "1" "$(has '90.34' "$out")"
rm -rf "$D"

# ── coverage below baseline (regression): exit 1 ──────────────────────
D="$(mktemp -d)"; make_report "$D/cob.xml" 0.80; printf '85\n' > "$D/base"
run --report "$D/cob.xml" --baseline "$D/base"
assert_eq "below baseline: exit 1" "1" "$rc"
rm -rf "$D"

# ── first run seeds the baseline from parsed coverage ─────────────────
D="$(mktemp -d)"; make_report "$D/cob.xml" 0.90
run --report "$D/cob.xml" --baseline "$D/base"
assert_eq "seed: exit 0" "0" "$rc"
assert_eq "seed: baseline is 90.00" "90.00" "$(base_of "$D/base")"
rm -rf "$D"

# ── missing report: skipped, exit 0 ───────────────────────────────────
D="$(mktemp -d)"; printf '85\n' > "$D/base"
run --report "$D/none.xml" --baseline "$D/base"
assert_eq "missing report: exit 0" "0" "$rc"
assert_eq "missing report: says skipped" "1" "$(has skipped "$out")"
rm -rf "$D"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
