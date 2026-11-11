#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# audit-app-preferences.sh — Deprecation-window lint for the legacy
# `Vauchi::app_preferences*` settings surface (ADR-047 / settings-storage-
# by-sensitivity plan, stage S5).
#
# S4 migrated every frontend off `Vauchi::app_preferences()` /
# `set_app_preferences()` to OS-native per-platform storage. S5 is a
# one-release deprecation window before S6 deletes the core surface
# (`storage/app_preferences.rs`, the two `Vauchi` methods, the mobile
# bridge + tests). This lint guards that window: it FAILS if a NEW
# frontend caller of the deprecated method reappears, so the surface
# cannot quietly regrow callers between S4 and S6.
#
# Ratchet semantics (same as audit-frontend-vocab.sh): per-repo caller
# counts may DROP as `set_app_preferences` write-path callers are also
# retired, never RISE. Baseline locked at 0 (S4 left zero frontend
# callers). The core method DEFINITIONS and core-internal callers are
# out of scope — they are the implementation S6 removes, not frontend
# callers; this lint only scans handwritten FRONTEND source.
#
# Plan: _private/docs/planning/todo/2026-05-16-settings-storage-by-sensitivity-plan.md (S5).
#
# SCOPE — counts exactly ONE thing per repo:
#   app_pref_callers — a method CALL of the deprecated surface in
#   handwritten frontend source. Matched as a leading-dot method call so
#   comments/backticked prose and the core `fn`/path definitions do not
#   count. Covers all four spellings the bindings expose:
#       .app_preferences(        / .set_app_preferences(     (Rust: cli, tui, linux-gtk)
#       .appPreferences(         / .setAppPreferences(        (UniFFI camelCase: Swift, Kotlin)
#
# Usage:
#   audit-app-preferences.sh [workspace_root]
#       Emit the JSON snapshot on stdout. Exit 0 (the JSON is the
#       result); exit 2 only on internal error (bad workspace root).
#   audit-app-preferences.sh --check <baseline.json> [workspace_root]
#       Ratchet mode. Compare each current total against the baseline;
#       exit 1 if ANY count EXCEEDS its baseline value (a new caller).
#       Counts at or below baseline pass (exit 0).
#
# Default workspace_root: two levels up from this script (so
# scripts/scripts/audit-app-preferences.sh resolves to .../vauchi-1/).
#
# Handwritten frontend source counted (skipped when a tree is absent):
#   android/app/src/main (Kotlin)  ios/Vauchi (Swift)  cli/src tui/src
#   (Rust)  linux-gtk linux-qt windows web-demo/src
# Excluded subpaths (binding mirrors / generated / vendored / build /
# locales / tests): /Generated/, /uniffi/, /Libs/, /build/, /.build/,
# /locales/, and test trees (/test/, /androidTest/, /Tests/,
# *Tests.swift, *Test.kt).
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
        printf 'audit-app-preferences: --check requires a baseline file\n' >&2
        exit 2
    fi
    if [ ! -f "$BASELINE_FILE" ]; then
        printf 'audit-app-preferences: baseline %s not found\n' "$BASELINE_FILE" >&2
        exit 2
    fi
    shift 2
fi

# ── locate workspace root ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${1:-$DEFAULT_ROOT}"

if [ ! -d "$WORKSPACE_ROOT" ]; then
    printf 'audit-app-preferences: workspace_root %s is not a directory\n' \
        "$WORKSPACE_ROOT" >&2
    exit 2
fi
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"

# ── exclusion filter ─────────────────────────────────────────────────
# Drop binding mirrors, generated code, vendored SPM, build output,
# locale tables, and test trees. Applied as a `grep -v` chain on the
# `path:lineno:line` output of the recursive grep (BusyBox-safe).
strip_excluded() {
    grep -v '/Generated/' \
        | grep -v '/uniffi/' \
        | grep -v '/Libs/' \
        | grep -v '/build/' \
        | grep -v '/.build/' \
        | grep -v '/locales/' \
        | grep -v '/test/' \
        | grep -v '/androidTest/' \
        | grep -v '/Tests/' \
        | grep -v 'Tests\.swift' \
        | grep -v 'Test\.kt' \
        || true
}

# ── core counter ──────────────────────────────────────────────────────
# app_pref_callers <src_root>
# Count lines under <src_root> that call the deprecated surface as a
# leading-dot method call. The `\.` anchor keeps the core method
# DEFINITIONS (`fn app_preferences`, `Vauchi::app_preferences`) and
# backticked prose in comments (`appPreferences()`) out of the count.
# Single ERE matches read+write, snake+camel. Missing root → 0.
app_pref_callers() {
    root="$1"
    [ -d "$root" ] || { printf '0'; return; }
    n=$(grep -rsnE '\.(set_?)?[aA]pp[_]?[pP]references *\(' "$root" 2>/dev/null \
        | strip_excluded \
        | grep -c '' || true)
    printf '%s' "${n:-0}"
}

# ── per-repo frontend source roots ────────────────────────────────────
callers_android=$(app_pref_callers "$WORKSPACE_ROOT/android/app/src/main")
callers_ios=$(app_pref_callers "$WORKSPACE_ROOT/ios/Vauchi")
callers_cli=$(app_pref_callers "$WORKSPACE_ROOT/cli/src")
callers_tui=$(app_pref_callers "$WORKSPACE_ROOT/tui/src")
# ADR-078 renamed linux-gtk and linux-qt (private#1029). A checkout that
# still has the old directory is read there; looking for one name only
# would count nothing in it and pass.
GTK_DIR=gtk-display
[ -d "$WORKSPACE_ROOT/gtk-display" ] || [ ! -d "$WORKSPACE_ROOT/linux-gtk" ] || GTK_DIR=linux-gtk
QT_DIR=qt-display
[ -d "$WORKSPACE_ROOT/qt-display" ] || [ ! -d "$WORKSPACE_ROOT/linux-qt" ] || QT_DIR=linux-qt
callers_linux_gtk=$(app_pref_callers "$WORKSPACE_ROOT/$GTK_DIR")
callers_linux_qt=$(app_pref_callers "$WORKSPACE_ROOT/$QT_DIR")
callers_windows=$(app_pref_callers "$WORKSPACE_ROOT/windows")
callers_web_demo=$(app_pref_callers "$WORKSPACE_ROOT/web-demo/src")
callers_total=$((callers_android + callers_ios + callers_cli + callers_tui \
    + callers_linux_gtk + callers_linux_qt + callers_windows + callers_web_demo))

# ── timestamp (BSD + GNU + BusyBox safe) ─────────────────────────────
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── render JSON ───────────────────────────────────────────────────────
emit_json() {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "captured_at": "%s",\n' "$captured_at"
    printf '  "workspace_root": "%s",\n' "$WORKSPACE_ROOT"
    printf '  "totals": {\n'
    printf '    %-34s %d,\n' '"app_pref_callers_android":'   "$callers_android"
    printf '    %-34s %d,\n' '"app_pref_callers_ios":'       "$callers_ios"
    printf '    %-34s %d,\n' '"app_pref_callers_cli":'       "$callers_cli"
    printf '    %-34s %d,\n' '"app_pref_callers_tui":'       "$callers_tui"
    printf '    %-34s %d,\n' '"app_pref_callers_linux_gtk":' "$callers_linux_gtk"
    printf '    %-34s %d,\n' '"app_pref_callers_linux_qt":'  "$callers_linux_qt"
    printf '    %-34s %d,\n' '"app_pref_callers_windows":'   "$callers_windows"
    printf '    %-34s %d,\n' '"app_pref_callers_web_demo":'  "$callers_web_demo"
    printf '    %-34s %d\n'  '"app_pref_callers_total":'     "$callers_total"
    printf '  }\n'
    printf '}\n'
}

# ── plain (snapshot) mode ─────────────────────────────────────────────
if [ "$CHECK_MODE" -eq 0 ]; then
    emit_json
    exit 0
fi

# ── --check (ratchet) mode ────────────────────────────────────────────
# A current count ABOVE its baseline is a new caller (the surface is
# being deprecated; callers may only drop). Missing baseline key → 0.
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
        printf 'NEW CALLER %s: baseline %d, now %d (deprecated Vauchi::app_preferences* — migrate to OS-native per S4)\n' \
            "$name" "$base" "$current" >&2
        regressions=$((regressions + 1))
    fi
}

check_one 'app_pref_callers_android'   "$callers_android"
check_one 'app_pref_callers_ios'       "$callers_ios"
check_one 'app_pref_callers_cli'       "$callers_cli"
check_one 'app_pref_callers_tui'       "$callers_tui"
check_one 'app_pref_callers_linux_gtk' "$callers_linux_gtk"
check_one 'app_pref_callers_linux_qt'  "$callers_linux_qt"
check_one 'app_pref_callers_windows'   "$callers_windows"
check_one 'app_pref_callers_web_demo'  "$callers_web_demo"
check_one 'app_pref_callers_total'     "$callers_total"

if [ "$regressions" -gt 0 ]; then
    printf 'audit-app-preferences: %d new caller(s) exceeded baseline %s\n' \
        "$regressions" "$BASELINE_FILE" >&2
    exit 1
fi

printf 'audit-app-preferences: OK — all counts at or below baseline %s\n' \
    "$BASELINE_FILE"
exit 0
