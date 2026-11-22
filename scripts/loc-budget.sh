#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# loc-budget.sh — "Less code is better": the handwritten frontend LOC
# budget. Counts non-blank lines of handwritten frontend source, one
# counter per repo, and ratchets them: the budget may DROP as the
# pure-functional-core program deletes shell code, never RISE.
# Generated code, binding mirrors, vendored checkouts, test trees and
# dependency/build output are excluded — only code a human maintains
# counts against the budget.
#
# Origin: same program as audit-mobile-surface.sh /
#         audit-shell-surface.sh (pure-functional-core / "frontends are
#         shells", plan
#         _private/docs/planning/todo/2026-05-11-pure-functional-core-program-plan.md).
#         The LOC budget is the program's coarsest gauge: every
#         retired Mobile* call, deleted view and collapsed ViewModel
#         shows up here first.
#
# Usage:
#   loc-budget.sh [workspace_root]
#       Emit the JSON snapshot on stdout. Exit 0 (the JSON is the
#       result); exit 2 only on internal error (bad workspace root).
#   loc-budget.sh --check <baseline.json> [workspace_root]
#       Ratchet mode. Compare each current total against the baseline;
#       exit 1 if ANY total EXCEEDS its baseline value (a regression).
#       Counts at or below baseline pass (exit 0) — decreases are the
#       goal, never a failure.
#
# Default workspace_root: two levels up from this script (so
# scripts/scripts/loc-budget.sh resolves to the workspace root).
#
# Counted source (one counter per repo; a missing root contributes 0,
# so the script also runs in a single-repo CI checkout):
#   ios         ios/Vauchi/**/*.swift
#   android     android/app/src/main/**/*.kt
#   linux-gtk   linux-gtk/src/**/*.rs
#   linux-qt    linux-qt/src/**/*.cpp, *.h   (C++ — the Qt frontend is
#               not Rust; counted as-is, headers included)
#   macos       macos/Vauchi/**/*.swift
#   windows     windows/Vauchi/**/*.cs       (C# only; XAML markup and
#               obj//bin/ build output excluded; the Vauchi.Tests and
#               Vauchi.UnitTests trees are siblings of this root)
#   tui         tui/src/**/*.rs
#   web-demo    web-demo/src/**/*.ts, *.tsx  (code only; *.css excluded)
#
# Excluded everywhere: /Generated/, /generated/, /Bindings/, /Libs/
# (local SPM binding checkouts), /.build/, /Tests/, /node_modules/,
# /dist/; plus /obj/ and /bin/ for the windows tree only (linux-gtk
# legitimately keeps handwritten sources in linux-gtk/src/bin/).
#
# A "line of code" is a line containing at least one non-whitespace
# character: blank lines are free, comments count (a deleted comment
# is less to maintain too).
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
        printf 'loc-budget: --check requires a baseline file\n' >&2
        exit 2
    fi
    if [ ! -f "$BASELINE_FILE" ]; then
        printf 'loc-budget: baseline %s not found\n' "$BASELINE_FILE" >&2
        exit 2
    fi
    shift 2
fi

# ── locate workspace root ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${1:-$DEFAULT_ROOT}"

if [ ! -d "$WORKSPACE_ROOT" ]; then
    printf 'loc-budget: workspace_root %s is not a directory\n' \
        "$WORKSPACE_ROOT" >&2
    exit 2
fi
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"

# ── core counter ──────────────────────────────────────────────────────
# handwritten_loc <src_root> <ext_regex> [extra_exclude_regex]
# Count non-blank lines across the handwritten source files under
# <src_root> whose extension matches <ext_regex> (an ERE alternation
# without the dot, e.g. "swift", "ts|tsx", "cpp|h"). Generated code,
# binding mirrors, vendored checkouts, test trees and dependency/build
# output are filtered out of the file list before counting; the
# optional third argument is an extra per-repo path filter (used to
# drop windows obj//bin/ build output without excluding the legitimate
# linux-gtk/src/bin/ tree). Missing root or no surviving files → 0.
# `|| true` swallows the grep/xargs exit-1 on an empty intermediate
# under `set -euo pipefail` (same pattern as audit-frontend-vocab.sh).
handwritten_loc() {
    root="$1"; exts="$2"; extra_exclude="${3:-}"
    [ -d "$root" ] || { printf '0'; return; }
    files=$(find "$root" -type f 2>/dev/null \
        | grep -E "\.(${exts})\$" \
        | grep -v '/Generated/' \
        | grep -v '/generated/' \
        | grep -v '/Bindings/' \
        | grep -v '/Libs/' \
        | grep -v '/\.build/' \
        | grep -v '/Tests/' \
        | grep -v '/node_modules/' \
        | grep -v '/dist/' \
        || true)
    if [ -n "$extra_exclude" ]; then
        files=$(printf '%s\n' "$files" | grep -vE "$extra_exclude" || true)
    fi
    # Drop the empty line printf emits for an empty list.
    files=$(printf '%s\n' "$files" | grep . || true)
    [ -n "$files" ] || { printf '0'; return; }
    n=$(printf '%s\n' "$files" \
        | xargs grep -E '[^[:space:]]' 2>/dev/null \
        | wc -l || true)
    printf '%d' "$((n + 0))"
}

# ── repo-relative frontend source roots ──────────────────────────────
IOS_SRC="$WORKSPACE_ROOT/ios/Vauchi"
ANDROID_SRC="$WORKSPACE_ROOT/android/app/src/main"
# ADR-078 renamed linux-gtk and linux-qt (private#1029). A checkout that
# still has the old directory is read there; looking for one name only
# would count nothing in it and pass.
GTK_DIR=gtk-display
[ -d "$WORKSPACE_ROOT/gtk-display" ] || [ ! -d "$WORKSPACE_ROOT/linux-gtk" ] || GTK_DIR=linux-gtk
QT_DIR=qt-display
[ -d "$WORKSPACE_ROOT/qt-display" ] || [ ! -d "$WORKSPACE_ROOT/linux-qt" ] || QT_DIR=linux-qt
LINUX_GTK_SRC="$WORKSPACE_ROOT/$GTK_DIR/src"
LINUX_QT_SRC="$WORKSPACE_ROOT/$QT_DIR/src"
MACOS_SRC="$WORKSPACE_ROOT/macos/Vauchi"
# windows was renamed to windows-app (private#1234); a checkout that has
# not followed is read under its old name.
WIN_DIR=windows-app
[ -d "$WORKSPACE_ROOT/windows-app" ] || [ ! -d "$WORKSPACE_ROOT/windows" ] || WIN_DIR=windows
WINDOWS_SRC="$WORKSPACE_ROOT/$WIN_DIR/Vauchi"
TUI_SRC="$WORKSPACE_ROOT/tui/src"
WEB_DEMO_SRC="$WORKSPACE_ROOT/web-demo/src"

# ── counters ─────────────────────────────────────────────────────────
ios_handwritten_loc=$(handwritten_loc "$IOS_SRC" 'swift')
android_handwritten_loc=$(handwritten_loc "$ANDROID_SRC" 'kt')
linux_gtk_handwritten_loc=$(handwritten_loc "$LINUX_GTK_SRC" 'rs')
linux_qt_handwritten_loc=$(handwritten_loc "$LINUX_QT_SRC" 'cpp|h')
macos_handwritten_loc=$(handwritten_loc "$MACOS_SRC" 'swift')
windows_handwritten_loc=$(handwritten_loc "$WINDOWS_SRC" 'cs' '/(obj|bin)/')
tui_handwritten_loc=$(handwritten_loc "$TUI_SRC" 'rs')
web_demo_handwritten_loc=$(handwritten_loc "$WEB_DEMO_SRC" 'ts|tsx')
handwritten_loc_total=$(( \
    ios_handwritten_loc \
    + android_handwritten_loc \
    + linux_gtk_handwritten_loc \
    + linux_qt_handwritten_loc \
    + macos_handwritten_loc \
    + windows_handwritten_loc \
    + tui_handwritten_loc \
    + web_demo_handwritten_loc \
))

# ── timestamp (BSD + GNU + BusyBox safe) ─────────────────────────────
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── render JSON to a variable ─────────────────────────────────────────
# Plain printf — no jq. All values are integers, so no escaping needed.
# The last total omits its trailing comma. In --check mode the snapshot
# is recomputed from the live tree (captured_at differs from baseline;
# only the totals are compared).
emit_json() {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "captured_at": "%s",\n' "$captured_at"
    printf '  "workspace_root": "%s",\n' "$WORKSPACE_ROOT"
    printf '  "totals": {\n'
    printf '    %-32s %d,\n' '"ios_handwritten_loc":'       "$ios_handwritten_loc"
    printf '    %-32s %d,\n' '"android_handwritten_loc":'   "$android_handwritten_loc"
    printf '    %-32s %d,\n' '"linux_gtk_handwritten_loc":' "$linux_gtk_handwritten_loc"
    printf '    %-32s %d,\n' '"linux_qt_handwritten_loc":'  "$linux_qt_handwritten_loc"
    printf '    %-32s %d,\n' '"macos_handwritten_loc":'     "$macos_handwritten_loc"
    printf '    %-32s %d,\n' '"windows_handwritten_loc":'   "$windows_handwritten_loc"
    printf '    %-32s %d,\n' '"tui_handwritten_loc":'       "$tui_handwritten_loc"
    printf '    %-32s %d,\n' '"web_demo_handwritten_loc":'  "$web_demo_handwritten_loc"
    printf '    %-32s %d\n'  '"handwritten_loc_total":'     "$handwritten_loc_total"
    printf '  }\n'
    printf '}\n'
}

# ── plain (snapshot) mode ─────────────────────────────────────────────
if [ "$CHECK_MODE" -eq 0 ]; then
    emit_json
    exit 0
fi

# ── --check (ratchet) mode ────────────────────────────────────────────
# Read each baseline total and compare. A current total ABOVE its
# baseline is a regression (the LOC budget may only drop). A baseline
# missing a key is treated as 0 (new counter → must be 0).
#
# baseline_value <key> — pull `"key": N` from the baseline JSON. POSIX
# awk, same shape as audit-frontend-vocab.sh's baseline_value.
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
        printf 'REGRESSION %s: baseline %d, now %d (handwritten LOC budget must not rise)\n' \
            "$name" "$base" "$current" >&2
        regressions=$((regressions + 1))
    fi
}

check_one 'ios_handwritten_loc'       "$ios_handwritten_loc"
check_one 'android_handwritten_loc'   "$android_handwritten_loc"
check_one 'linux_gtk_handwritten_loc' "$linux_gtk_handwritten_loc"
check_one 'linux_qt_handwritten_loc'  "$linux_qt_handwritten_loc"
check_one 'macos_handwritten_loc'     "$macos_handwritten_loc"
check_one 'windows_handwritten_loc'   "$windows_handwritten_loc"
check_one 'tui_handwritten_loc'       "$tui_handwritten_loc"
check_one 'web_demo_handwritten_loc'  "$web_demo_handwritten_loc"
check_one 'handwritten_loc_total'     "$handwritten_loc_total"

if [ "$regressions" -gt 0 ]; then
    printf 'loc-budget: %d counter(s) exceeded baseline %s\n' \
        "$regressions" "$BASELINE_FILE" >&2
    exit 1
fi

printf 'loc-budget: OK — all totals at or below baseline %s\n' \
    "$BASELINE_FILE"
exit 0
