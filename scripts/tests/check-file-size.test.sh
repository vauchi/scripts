#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-file-size-test.sh — behavior tests for check-file-size.sh
#
# Exercises the ratchet through the script's CLI (exit code + output),
# not its internals: non-baselined thresholds, the bucketed ceiling
# ratchet, the `exempt` marker, `// allow(large_file)` suppression, and
# `--generate-baseline` exempt preservation.
#
# Run: scripts/tests/check-file-size-test.sh   (exit 0 = all pass)

set -euo pipefail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$SCRIPT_DIR/check-file-size.sh"

PASS=0
FAIL=0

# make_lines <count> <path> — write a file with exactly <count> lines.
make_lines() {
    awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++) print "x" }' > "$2"
}

# run_check <args...> — run the checker; sets OUT (combined output) and RC.
run_check() {
    OUT="$("$CHECK" "$@" 2>&1)"
    RC=$?
}

# expect_rc <expected> <label>
expect_rc() {
    if [ "$RC" = "$1" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL — $2 (exit $RC, expected $1)"
        printf '%s\n' "----- output -----" "$OUT" "------------------"
    fi
}

# expect_contains <needle> <label>
expect_contains() {
    case "$OUT" in
        *"$1"*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            echo "FAIL — $2 (output missing '$1')"
            printf '%s\n' "----- output -----" "$OUT" "------------------"
            ;;
    esac
}

# ── Case 1: non-baselined file over error threshold fails ──────────────
WS=$(mktemp -d)
make_lines 1500 "$WS/big.rs"
run_check "$WS"
expect_rc 1 "non-baselined src over error threshold fails"
rm -rf "$WS"

# ── Case 2: non-baselined small file passes ───────────────────────────
WS=$(mktemp -d)
make_lines 300 "$WS/small.rs"
run_check "$WS"
expect_rc 0 "non-baselined small file passes"
rm -rf "$WS"

# ── Case 3: baselined file grown within the bucket ceiling passes ──────
# baseline 1035 → ceiling 1100; a 1050-line file used to fail (+15) and
# must now pass. This is the churn fix.
WS=$(mktemp -d)
make_lines 1050 "$WS/grown.rs"
printf 'grown.rs 1035\n' > "$WS/.file-size-baseline"
run_check "$WS"
expect_rc 0 "baselined file within ceiling passes (no +1 churn)"
rm -rf "$WS"

# ── Case 4: baselined file grown past the bucket ceiling still fails ───
# baseline 1035 → ceiling 1100; a 1150-line file exceeds it → ratchet bites.
WS=$(mktemp -d)
make_lines 1150 "$WS/ballooned.rs"
printf 'ballooned.rs 1035\n' > "$WS/.file-size-baseline"
run_check "$WS"
expect_rc 1 "baselined file past ceiling still fails"
rm -rf "$WS"

# ── Case 5: ceiling boundary is inclusive of the ceiling value ────────
# baseline 1100 → ceiling 1100; exactly 1100 passes, 1101 fails.
WS=$(mktemp -d)
make_lines 1100 "$WS/edge.rs"
printf 'edge.rs 1100\n' > "$WS/.file-size-baseline"
run_check "$WS"
expect_rc 0 "file at ceiling passes"
make_lines 1101 "$WS/edge.rs"
run_check "$WS"
expect_rc 1 "file one past ceiling fails"
rm -rf "$WS"

# ── Case 6: exempt marker never fails regardless of size ──────────────
WS=$(mktemp -d)
make_lines 5000 "$WS/facade.rs"
printf 'facade.rs exempt\n' > "$WS/.file-size-baseline"
run_check "$WS"
expect_rc 0 "exempt file never fails"
rm -rf "$WS"

# ── Case 7: // allow(large_file) suppression passes ───────────────────
# Build the fixture so line 1 is the suppression marker. awk inherits the
# group's redirected stdout directly — do NOT route via `> /dev/stdout`,
# which re-opens and truncates the target file on Linux (wiping line 1)
# while silently working on macOS.
WS=$(mktemp -d)
{ echo '// allow(large_file)'; awk 'BEGIN { for (i = 0; i < 4999; i++) print "x" }'; } > "$WS/suppressed.rs"
run_check "$WS"
expect_rc 0 "suppressed file passes"
rm -rf "$WS"

# ── Case 8: --generate-baseline preserves exempt, rounds nothing ──────
# Existing baseline marks facade.rs exempt; regeneration must keep it
# exempt (not re-record a number) while emitting a plain count for a
# newly-oversized file.
WS=$(mktemp -d)
make_lines 1500 "$WS/facade.rs"
make_lines 1300 "$WS/plain.rs"
printf 'facade.rs exempt\n' > "$WS/.file-size-baseline"
run_check --generate-baseline "$WS"
expect_rc 0 "generate-baseline exits 0"
expect_contains "facade.rs exempt" "generate-baseline preserves exempt marker"
expect_contains "plain.rs 1300" "generate-baseline records plain oversized file"
rm -rf "$WS"

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "check-file-size-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
