#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-adr066-migration.sh — counts retired
# ScreenModel-era types and ratchets them downward (VRT01).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-adr066-migration.sh"

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
# Write $2 references to retired types under $1/src.
make_src() {
    mkdir -p "$1/src"
    : > "$1/src/views.kt"
    i=0; while [ "$i" -lt "$2" ]; do echo "val x = ScreenModel()" >> "$1/src/views.kt"; i=$((i + 1)); done
}
run() { out="$("$SCRIPT" "$@" 2>&1)"; rc=$?; }

# ── more than baseline (migration went backwards): exit 1 ─────────────
D="$(mktemp -d)"; make_src "$D" 5; printf '3\n' > "$D/base"
run --root "$D" --baseline "$D/base"
assert_eq "regress: exit 1" "1" "$rc"
assert_eq "regress: counted 5" "1" "$(has '5 retired-type' "$out")"
rm -rf "$D"

# ── fewer than baseline (migration progressed): exit 0 ────────────────
D="$(mktemp -d)"; make_src "$D" 2; printf '3\n' > "$D/base"
run --root "$D" --baseline "$D/base"
assert_eq "improve: exit 0" "0" "$rc"
assert_eq "improve: advises" "1" "$(has improved "$out")"
rm -rf "$D"

# ── first run seeds the baseline from the current count ───────────────
D="$(mktemp -d)"; make_src "$D" 4
run --root "$D" --baseline "$D/base"
assert_eq "seed: exit 0" "0" "$rc"
assert_eq "seed: baseline is 4" "4" "$(base_of "$D/base")"
rm -rf "$D"

# ── build artifacts are excluded from the count ───────────────────────
D="$(mktemp -d)"; make_src "$D" 3
mkdir -p "$D/target"; printf 'ScreenModel ScreenModel\n' > "$D/target/gen.kt"
printf '3\n' > "$D/base"
run --root "$D" --baseline "$D/base"
assert_eq "excludes target/: exit 0 (still 3)" "0" "$rc"
assert_eq "excludes target/: at baseline" "1" "$(has 'at baseline' "$out")"
rm -rf "$D"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
