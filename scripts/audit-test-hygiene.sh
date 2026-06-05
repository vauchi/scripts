#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# audit-test-hygiene.sh — Ratchet for two test-quality rules that were
# honor-system (test-quality-rules.md): CC-06 (no real-time waits) and
# silent test skips. A TEXT regression ratchet, not a correctness proof.
#
# Mirrors audit-app-preferences.sh: per-counter ratchet, counts may DROP
# as debt is retired, never RISE. Baselines locked at the current count
# (acknowledged debt), so the gate prevents NEW occurrences while the
# existing ones are ratcheted down.
#
# Scope: core/vauchi-core/tests (the security-critical crate). Extendable
# to other crates / repos later. The pure-functional-core seal already
# guarantees production src owns no thread::sleep (sleeper.rs seam aside),
# so all real test waits live under tests/.
#
# Counters:
#   test_sleeps   — CC-06. A real-time wait (thread::sleep / tokio sleep)
#                   in a test. Use the mockable-time seam (sleeper.rs) or
#                   event sync instead — real sleeps make tests flaky and
#                   slow. Baseline = current; ratchet to 0.
#   silent_skips  — an `eprintln!("SKIP …"); return;`-style soft skip that
#                   makes a test report PASS when its precondition is
#                   absent (e.g. a sibling repo not cloned). In CI the deps
#                   ARE present, so the skip is dead weight that would hide
#                   a real break. Use #[ignore] (explicit) or assert the
#                   precondition holds. Baseline = current; ratchet to 0.
#
# Usage:
#   audit-test-hygiene.sh [workspace_root]
#       JSON snapshot on stdout (exit 0; exit 2 on bad workspace root).
#   audit-test-hygiene.sh --check <baseline.json> [workspace_root]
#       Ratchet mode. Exit 1 if ANY count EXCEEDS its baseline.
#
# Portability: POSIX shell + BSD/GNU/BusyBox utilities only. No grep -P,
# no bash arrays, no GNU --include/--exclude, no mapfile.

set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────────
CHECK_MODE=0
BASELINE_FILE=""
if [ "${1:-}" = "--check" ]; then
    CHECK_MODE=1
    BASELINE_FILE="${2:-}"
    if [ -z "$BASELINE_FILE" ]; then
        printf 'audit-test-hygiene: --check requires a baseline file\n' >&2
        exit 2
    fi
    if [ ! -f "$BASELINE_FILE" ]; then
        printf 'audit-test-hygiene: baseline %s not found\n' "$BASELINE_FILE" >&2
        exit 2
    fi
    shift 2
fi

# ── locate workspace root + test tree ─────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${1:-$DEFAULT_ROOT}"

if [ ! -d "$WORKSPACE_ROOT" ]; then
    printf 'audit-test-hygiene: workspace_root %s is not a directory\n' \
        "$WORKSPACE_ROOT" >&2
    exit 2
fi
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"
TEST_DIR="$WORKSPACE_ROOT/core/vauchi-core/tests"

# ── strip comment-only lines (input is `path:lineno:code`) ────────────
strip_comments() {
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*)' || true
}

# ── counters ──────────────────────────────────────────────────────────
test_sleeps() {
    [ -d "$TEST_DIR" ] || { printf '0'; return; }
    n=$(grep -rsnE 'thread::sleep|tokio::time::sleep' "$TEST_DIR" 2>/dev/null \
        | strip_comments | grep -c '' || true)
    printf '%s' "${n:-0}"
}
silent_skips() {
    [ -d "$TEST_DIR" ] || { printf '0'; return; }
    n=$(grep -rsnE 'e?println!\("SKIP' "$TEST_DIR" 2>/dev/null \
        | strip_comments | grep -c '' || true)
    printf '%s' "${n:-0}"
}

test_sleeps_n=$(test_sleeps)
silent_skips_n=$(silent_skips)
test_hygiene_total=$((test_sleeps_n + silent_skips_n))

# ── render JSON ───────────────────────────────────────────────────────
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
emit_json() {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "captured_at": "%s",\n' "$captured_at"
    printf '  "workspace_root": "%s",\n' "$WORKSPACE_ROOT"
    printf '  "totals": {\n'
    printf '    %-24s %d,\n' '"test_sleeps":'        "$test_sleeps_n"
    printf '    %-24s %d,\n' '"silent_skips":'       "$silent_skips_n"
    printf '    %-24s %d\n'  '"test_hygiene_total":' "$test_hygiene_total"
    printf '  }\n'
    printf '}\n'
}

if [ "$CHECK_MODE" -eq 0 ]; then
    emit_json
    exit 0
fi

# ── --check (ratchet) mode ────────────────────────────────────────────
baseline_value() {
    awk -v k="\"$1\"" '
        $1 ~ k { v = $0; sub(/.*:[[:space:]]+/, "", v); sub(/,$/, "", v); print v + 0; exit }
    ' "$BASELINE_FILE"
}

regressions=0
check_one() {
    name="$1"; current="$2"
    base=$(baseline_value "$name"); base="${base:-0}"
    if [ "$current" -gt "$base" ]; then
        printf 'REGRESSION %s: baseline %d, now %d\n' "$name" "$base" "$current" >&2
        regressions=$((regressions + 1))
    fi
}

check_one 'test_sleeps'        "$test_sleeps_n"
check_one 'silent_skips'       "$silent_skips_n"
check_one 'test_hygiene_total' "$test_hygiene_total"

if [ "$regressions" -gt 0 ]; then
    printf 'audit-test-hygiene: %d test-hygiene regression(s) above baseline %s\n' \
        "$regressions" "$BASELINE_FILE" >&2
    printf 'CC-06 (no real-time waits) / no silent skips. Use mockable time / #[ignore].\n' >&2
    exit 1
fi

printf 'audit-test-hygiene: OK — all counts at or below baseline %s\n' "$BASELINE_FILE"
exit 0
