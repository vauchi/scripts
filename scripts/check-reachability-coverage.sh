#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# CC-22 reachability-coverage gate.
#
# Two checks, each with a clear remediation:
#
#  (1) Every `impl WorkflowEngine for X` has either a matching
#      `tests/reachability/<snake_case>.rs` or an entry in the
#      `.coverage-baseline` grandfather list. Adding a new engine
#      without a test fails this check.
#
#  (2) Every entry in `.coverage-baseline` has NO matching test file.
#      When a test lands for a baseline entry, the entry must be
#      removed in the same MR. This forces the baseline to ratchet
#      down toward zero.
#
# Run from the workspace root.
#
# Portable-shell rules (`.claude/rules/portable-shell.md`):
#   - POSIX `sh`, no bashisms
#   - no `grep -P`, no `sed -i ''` form, no GNU-only flags
#   - `tr` for case conversion (works on macOS / Linux / BusyBox)
#
# Audit reference:
#   `_private/docs/investigations/2026-05-08-architecture-adr-compliance-audit.md`
#   findings F4 / R-4 / P-11.

set -eu

ROOT_DIR="${ROOT_DIR:-$(pwd)}"
SRC_DIR="$ROOT_DIR/core/vauchi-app/src/ui"
TEST_DIR="$ROOT_DIR/core/vauchi-app/tests/reachability"
BASELINE="$TEST_DIR/.coverage-baseline"

if [ ! -d "$SRC_DIR" ]; then
    printf 'error: %s not found — run from workspace root\n' "$SRC_DIR" >&2
    exit 2
fi
if [ ! -f "$BASELINE" ]; then
    printf 'error: %s missing — restore from git\n' "$BASELINE" >&2
    exit 2
fi

# Convert CamelCase engine name → snake_case test stem.
# Strips trailing "Engine", then inserts `_` at lower→Upper boundaries,
# then lower-cases. Pure POSIX `sed` + `tr`.
to_snake() {
    printf '%s\n' "$1" \
        | sed -e 's/Engine$//' \
              -e 's/\([a-z0-9]\)\([A-Z]\)/\1_\2/g' \
        | tr 'A-Z' 'a-z'
}

# Engines: every `impl WorkflowEngine for X` in core/vauchi-app/src/ui.
ENGINES=$(grep -rh '^impl WorkflowEngine for ' "$SRC_DIR" \
              | sed -e 's/^impl WorkflowEngine for //' \
                    -e 's/[ {].*$//' \
              | sort -u)

# Baseline: skip comments and blanks.
read_baseline() {
    sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$BASELINE" | sort -u
}
BASELINED=$(read_baseline)

missing=0
forbidden=0

# Check 1: every engine has a test or is grandfathered.
for engine in $ENGINES; do
    snake=$(to_snake "$engine")
    if [ -f "$TEST_DIR/$snake.rs" ]; then
        continue
    fi
    if printf '%s\n' "$BASELINED" | grep -qx "$engine"; then
        continue
    fi
    if [ "$missing" -eq 0 ]; then
        printf 'CC-22 missing reachability test:\n' >&2
    fi
    missing=$((missing + 1))
    printf '  %s — expected %s/%s.rs\n' "$engine" "tests/reachability" "$snake" >&2
done

# Check 2: every baseline entry has NO test (ratchet shrinkage).
for entry in $BASELINED; do
    snake=$(to_snake "$entry")
    if [ -f "$TEST_DIR/$snake.rs" ]; then
        if [ "$forbidden" -eq 0 ]; then
            printf 'baseline entries with shipped tests (remove from .coverage-baseline):\n' >&2
        fi
        forbidden=$((forbidden + 1))
        printf '  %s — %s/%s.rs exists\n' "$entry" "tests/reachability" "$snake" >&2
    fi
done

if [ "$missing" -gt 0 ] || [ "$forbidden" -gt 0 ]; then
    printf '\n' >&2
    if [ "$missing" -gt 0 ]; then
        printf 'fix: add the missing reachability test, OR add the engine name to %s\n' "$BASELINE" >&2
        printf '     (only acceptable when the engine is intentionally unowned;\n' >&2
        printf '      every entry there is technical debt by definition)\n' >&2
    fi
    if [ "$forbidden" -gt 0 ]; then
        printf 'fix: delete the baseline line(s) above so the gate ratchets down\n' >&2
    fi
    exit 1
fi
