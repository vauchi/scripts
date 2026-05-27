#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# audit-dispatch-purity.sh — Dispatch-wrapper pass-through purity gate.
#
# The enforcement keystone for ADR-043 Amendment 3 §2's *conditional*
# sanction of the `dispatch_domain_command` surface: the per-operation
# typed wrappers in the two frontend dispatch-extension files are humble
# ONLY IF they are opaque pass-through (a single `dispatchDomainCommand`
# call + the sanctioned typed-result unwrap idiom — no domain branching,
# filtering, formatting, arithmetic, multi-call aggregation, or caching).
# The method-name-only humble metric (`pae_non_humble = 0`) cannot see
# that condition; this gate makes it measurable.
#
# Sibling of audit-frontend-vocab.sh (the nav-vocabulary deny-list) and
# of core/vauchi-app/tests/it/wire_humble_keys_tests.rs (the wire-side
# deny-list). Same ratchet shape: a floor that may DROP, never RISE.
#
# Origin: _private/docs/planning/todo/2026-05-26-humble-ui-vocab-fast-path-plan.md
#         Lever 3 / L3.2.
#
# SCOPE — counts exactly ONE category, per file:
#   impure_dispatch_lines — a line in a dispatch-extension file matching a
#   known *impurity signal*: a collection transform, a string/number/date
#   formatter, or statement-level branching. The sanctioned unwrap idiom
#   (`(result as? DomainCommandResult.X)?.field ?: unexpectedResult(...)`
#   in Kotlin; `guard case let .x(value) = result else { throw ... }` in
#   Swift) uses none of these tokens, so a pure file scores 0.
#
# Deliberately NOT counted: multi-call aggregation (>1 dispatch call per
# wrapper) — that is not a single-line signal; the companion test and the
# L2.1 audit cover it qualitatively.
#
# Usage:
#   audit-dispatch-purity.sh [workspace_root]
#       Emit the JSON snapshot on stdout. Exit 0 (the JSON is the result);
#       exit 2 only on internal error (bad workspace root).
#   audit-dispatch-purity.sh --check <baseline.json> [workspace_root]
#       Ratchet mode. Exit 1 if ANY total EXCEEDS its baseline value.
#
# Default workspace_root: two levels up from this script.
#
# Files audited (the two hand-written dispatch-extension files):
#   android/app/src/main/kotlin/app/vauchi/data/PlatformAppEngineDomainDispatch.kt
#   ios/Vauchi/Services/PlatformAppEngine+DomainDispatch.swift
#
# Portability: POSIX shell + BSD/GNU/BusyBox-portable utilities only.
# No grep -P, no bash arrays, no GNU --include/--exclude, no mapfile.

set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────────
CHECK_MODE=0
BASELINE_FILE=""
if [ "${1:-}" = "--check" ]; then
    CHECK_MODE=1
    BASELINE_FILE="${2:-}"
    if [ -z "$BASELINE_FILE" ]; then
        printf 'audit-dispatch-purity: --check requires a baseline file\n' >&2
        exit 2
    fi
    if [ ! -f "$BASELINE_FILE" ]; then
        printf 'audit-dispatch-purity: baseline %s not found\n' "$BASELINE_FILE" >&2
        exit 2
    fi
    shift 2
fi

# ── locate workspace root ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${1:-$DEFAULT_ROOT}"

if [ ! -d "$WORKSPACE_ROOT" ]; then
    printf 'audit-dispatch-purity: workspace_root %s is not a directory\n' \
        "$WORKSPACE_ROOT" >&2
    exit 2
fi
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"

# ── impurity deny-list ────────────────────────────────────────────────
# High-signal tokens that must never appear in a pure pass-through
# wrapper. The sanctioned unwrap idiom contains none of them (verified
# against the live files at baseline 0). New legitimate shapes do NOT get
# added here as exemptions — if a wrapper needs one of these, the logic
# belongs in core (ADR-043 Am3 §2), not the wrapper. Anchored as a POSIX
# ERE alternation.
#   collection transforms : .filter( .map( .sorted .compactMap( .reduce(
#                           .groupBy( .sortedBy( .firstOrNull .first(where
#   formatters            : String(format DateFormatter NumberFormatter
#                           replacingOccurrences .replace( .uppercased(
#                           .lowercased( .prefix(
#   statement branching   : when ( | leading 'if ' | ' switch '
# NOTE: collection methods are matched followed by `(`, `{`, or space so
# Kotlin trailing-lambda syntax (`.filter { … }`) is caught, not just the
# call-paren form (`.filter(…)`).
IMPURE_ERE='\.filter[[:space:]]*[({]|\.map[[:space:]]*[({]|\.sorted|\.compactMap[[:space:]]*[({]|\.reduce[[:space:]]*[({]|\.groupBy[[:space:]]*[({]|\.firstOrNull|\.first\(where|String\(format|DateFormatter|NumberFormatter|replacingOccurrences|\.replace[[:space:]]*\(|\.uppercased\(|\.lowercased\(|\.prefix\(|when ?\(|[[:space:]]switch |^[[:space:]]*if '

# ── core counter ──────────────────────────────────────────────────────
# impure_dispatch_lines <file> — count lines in <file> matching the
# impurity deny-list. Missing file → 0 (a frontend's source tree is not
# present in that frontend's sibling CI checkout).
impure_dispatch_lines() {
    file="$1"
    [ -f "$file" ] || { printf '0'; return; }
    n=$(grep -cE "$IMPURE_ERE" "$file" 2>/dev/null || true)
    printf '%s' "${n:-0}"
}

# ── dispatch-extension file paths ─────────────────────────────────────
ANDROID_FILE="$WORKSPACE_ROOT/android/app/src/main/kotlin/app/vauchi/data/PlatformAppEngineDomainDispatch.kt"
IOS_FILE="$WORKSPACE_ROOT/ios/Vauchi/Services/PlatformAppEngine+DomainDispatch.swift"

# ── counters ─────────────────────────────────────────────────────────
impure_dispatch_lines_android=$(impure_dispatch_lines "$ANDROID_FILE")
impure_dispatch_lines_ios=$(impure_dispatch_lines "$IOS_FILE")
impure_dispatch_lines_total=$((impure_dispatch_lines_android + impure_dispatch_lines_ios))

# ── timestamp (BSD + GNU + BusyBox safe) ─────────────────────────────
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── render JSON ───────────────────────────────────────────────────────
emit_json() {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "captured_at": "%s",\n' "$captured_at"
    printf '  "workspace_root": "%s",\n' "$WORKSPACE_ROOT"
    printf '  "totals": {\n'
    printf '    %-36s %d,\n' '"impure_dispatch_lines_android":' "$impure_dispatch_lines_android"
    printf '    %-36s %d,\n' '"impure_dispatch_lines_ios":'     "$impure_dispatch_lines_ios"
    printf '    %-36s %d\n'  '"impure_dispatch_lines_total":'   "$impure_dispatch_lines_total"
    printf '  }\n'
    printf '}\n'
}

# ── plain (snapshot) mode ─────────────────────────────────────────────
if [ "$CHECK_MODE" -eq 0 ]; then
    emit_json
    exit 0
fi

# ── --check (ratchet) mode ────────────────────────────────────────────
baseline_value() {
    awk -v k="\"$1\"" '
        $1 ~ k {
            v = $0
            sub(/.*:[[:space:]]+/, "", v)
            sub(/,$/, "", v)
            print v + 0
            exit
        }
    ' "$BASELINE_FILE"
}

regressions=0
check_one() {
    name="$1"
    current="$2"
    base=$(baseline_value "$name")
    base="${base:-0}"
    if [ "$current" -gt "$base" ]; then
        printf 'REGRESSION %s: baseline %d, now %d (dispatch wrappers must stay pure pass-through)\n' \
            "$name" "$base" "$current" >&2
        regressions=$((regressions + 1))
    fi
}

check_one 'impure_dispatch_lines_android' "$impure_dispatch_lines_android"
check_one 'impure_dispatch_lines_ios'     "$impure_dispatch_lines_ios"
check_one 'impure_dispatch_lines_total'   "$impure_dispatch_lines_total"

if [ "$regressions" -gt 0 ]; then
    printf 'audit-dispatch-purity: %d counter(s) exceeded baseline %s\n' \
        "$regressions" "$BASELINE_FILE" >&2
    printf 'A dispatch wrapper grew domain logic — push it into core (ADR-043 Am3 §2).\n' >&2
    exit 1
fi

printf 'audit-dispatch-purity: OK — all totals at or below baseline %s\n' \
    "$BASELINE_FILE"
exit 0
