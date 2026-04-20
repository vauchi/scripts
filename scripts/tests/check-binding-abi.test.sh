#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-binding-abi.test.sh — Meta-test for the Layer 2 ABI
# parity gate.
#
# Plan: _private/docs/planning/todo/2026-04-20-frontend-correctness-strategy-plan.md
# Phase 5 Task 5.2. Proves the script catches the
# "deliberately-stale artifact" class of bug.
#
# Usage: scripts/tests/check-binding-abi.test.sh
#
# Requirements:
#   - Workspace with a built Android .so at the usual path, OR
#   - pass an absolute path as argv[1]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../check-binding-abi.sh"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Default Android artifact — override via argv[1] if needed.
DEFAULT_SO="$WORKSPACE_ROOT/core/target/aarch64-linux-android/release/libvauchi_platform.so"
REAL_SO="${1:-$DEFAULT_SO}"

if [[ ! -f "$REAL_SO" ]]; then
    # shellcheck disable=SC2016  # backticks are literal text in the SKIP message, not command substitution
    printf 'SKIP: no Android .so at %s (build with `just _dt-build-mobile-libs-android core`)\n' "$REAL_SO" >&2
    exit 77  # Automake-style "test skipped"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass_count=0
fail_count=0

report_pass() {
    printf '  PASS %s\n' "$1"
    pass_count=$((pass_count + 1))
}

report_fail() {
    printf '  FAIL %s\n  %s\n' "$1" "$2" >&2
    fail_count=$((fail_count + 1))
}

# ── Case 1: matched synthetic bindings + real .so → exit 0 ────

CASE1_BINDINGS="$TMP/case1_matched.kt"
# Use a symbol we know exists in every UniFFI artifact: the
# namespace metadata section anchor. Refer to it from the
# fixture the same way the real Kotlin bindings do.
cat > "$CASE1_BINDINGS" <<'EOF'
// synthetic fixture — references a symbol the real .so exports
// exactly once. Paired with the real .so, check-binding-abi.sh
// should still fail for the 778 other symbols the .so exports
// but this fixture doesn't reference. Expected: FAIL.
external fun uniffi_vauchi_platform_fn_func_core_version(): Pointer
EOF

if "$CHECK" \
    --platform android \
    --artifact "$REAL_SO" \
    --bindings "$CASE1_BINDINGS" >"$TMP/case1.stdout" 2>"$TMP/case1.stderr"
then
    report_fail "case 1 (one symbol in bindings, many in .so)" \
                "expected exit 1 (artifact has extra symbols); got exit 0"
else
    if grep -q "ABI parity FAILED" "$TMP/case1.stderr" \
       && grep -q "NOT referenced by bindings" "$TMP/case1.stderr"; then
        report_pass "case 1 (artifact has extra symbols → exit 1)"
    else
        report_fail "case 1 (artifact has extra symbols → exit 1)" \
                    "exit code was non-zero but the expected diagnostic is missing"
    fi
fi

# ── Case 2: stale bindings reference a missing symbol → exit 1

CASE2_BINDINGS="$TMP/case2_stale.kt"
cat > "$CASE2_BINDINGS" <<'EOF'
// synthetic fixture — references a symbol no real .so could
// ever export. Simulates the 2026-04-20 Android startup crash
// class: binding generated against a stale .so that still had
// `diagnostic_scan_qr` but the fresh .so does not.
external fun uniffi_vauchi_platform_fn_func_STALE_FIXTURE_NONEXISTENT(): Pointer
external fun uniffi_vauchi_platform_checksum_func_STALE_FIXTURE_NONEXISTENT(): Int
EOF

if "$CHECK" \
    --platform android \
    --artifact "$REAL_SO" \
    --bindings "$CASE2_BINDINGS" >"$TMP/case2.stdout" 2>"$TMP/case2.stderr"
then
    report_fail "case 2 (stale binding references missing symbol)" \
                "expected exit 1; got exit 0"
else
    # Must surface BOTH the specific missing symbol AND the
    # UnsatisfiedLinkError-prefixed section header, so CI
    # diagnostics are immediately useful.
    if grep -q "STALE_FIXTURE_NONEXISTENT" "$TMP/case2.stderr" \
       && grep -q "UnsatisfiedLinkError" "$TMP/case2.stderr"; then
        report_pass "case 2 (stale binding → missing symbol named in report)"
    else
        report_fail "case 2 (stale binding → missing symbol named in report)" \
                    "expected 'STALE_FIXTURE_NONEXISTENT' + 'UnsatisfiedLinkError' in stderr"
    fi
fi

# ── Case 3: invocation errors → exit 2 ────────────────────────

if "$CHECK" --platform android >/dev/null 2>&1; then
    report_fail "case 3 (missing args)" "expected exit 2; got exit 0"
else
    rc=$?
    if [[ "$rc" == 2 ]]; then
        report_pass "case 3 (missing --artifact/--bindings → exit 2)"
    else
        report_fail "case 3 (missing args)" "expected exit 2; got $rc"
    fi
fi

# ── Summary ───────────────────────────────────────────────────

printf '\ncheck-binding-abi.test.sh: %d passed, %d failed\n' \
    "$pass_count" "$fail_count"

exit $(( fail_count > 0 ))
