#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# audit-mobile-surface.sh — Ratchet floor for the pure-functional-core
# program. Counts every line that survives only because the old
# domain-typed binding surface used to need it.
#
# Origin: _private/docs/planning/todo/2026-05-11-pure-functional-core-program-plan.md
#         Phase 0 / Task 0.1 (Step 1)
#
# Usage:  audit-mobile-surface.sh [workspace_root]
# Default workspace_root: two levels up from this script (so
# scripts/scripts/audit-mobile-surface.sh resolves to .../vauchi-1/).
#
# Output: single JSON blob on stdout. Each counter is an integer; a
# subdir that does not exist contributes zero (so the same script can
# run in the workspace root or inside a single sub-repo's CI). Exits
# non-zero only on internal error — the JSON itself is the result.
#
# Portability: POSIX shell + BSD/GNU/BusyBox-portable utilities only.
# No grep -P, no GNU --include, no readlink -f.

set -euo pipefail

# ── locate workspace root ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${1:-$DEFAULT_ROOT}"

if [ ! -d "$WORKSPACE_ROOT" ]; then
    printf 'audit-mobile-surface: workspace_root %s is not a directory\n' \
        "$WORKSPACE_ROOT" >&2
    exit 2
fi

# Resolve to an absolute path so the JSON is human-readable.
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"

# ── allow-list of genuine Humble methods on PlatformAppEngine ────────
# Source: plan Task 0.2 — this is the target end-state surface. Every
# pub fn under `impl PlatformAppEngine { … }` whose name is NOT on this
# list counts as legacy debt and is retired in Phase 3.
PAE_ALLOWLIST="$(cat <<'EOF'
boot
current_screen_json
tab_info
sidebar_items
handle_action_json
handle_hardware_event
advance_qr_frame_json
navigate_to_json
navigate_back_json
handle_deep_link_uri
available_screens_json
default_screen_json
current_screen_id
current_tab_id
invalidate_all
invalidate_screen_json
has_identity
periodic_sync_tick
set_network_online
is_network_online
handle_app_backgrounded
poll_notifications
set_event_listener
drain_pending_notifications
set_device_capabilities_json
EOF
)"

# ── helpers ───────────────────────────────────────────────────────────
# count_lines_matching <regex> <path> [<path>...]
# Counts total lines (across all listed files/dirs) matching the
# extended-regex pattern. Missing paths contribute 0. POSIX-safe.
count_lines_matching() {
    local pattern="$1"
    shift
    local total=0 path
    for path in "$@"; do
        [ -e "$path" ] || continue
        # grep -rsE: recursive, suppress missing-file errors, ERE.
        local n
        n=$(grep -rsE "$pattern" "$path" 2>/dev/null | wc -l)
        total=$((total + n))
    done
    printf '%s' "$total"
}

# count_files_matching <name_pattern> <regex> <path>
# Glob over files matching a name pattern under <path>, count total
# matching lines across them. Useful for `mobile_*.rs` style scoping.
count_files_matching() {
    local name="$1" pattern="$2" root="$3"
    [ -d "$root" ] || { printf '0'; return; }
    # find + grep portably; avoid -print0/xargs to stay BusyBox-safe.
    local n
    n=$(find "$root" -type f -name "$name" -exec grep -E "$pattern" {} + 2>/dev/null | wc -l)
    printf '%s' "$n"
}

# pae_pub_fn_names — emit one method name per line for every `pub fn`
# inside `impl PlatformAppEngine { … }` blocks under the given root.
# Uses column-anchored brace counting: rustfmt guarantees `impl …` and
# the matching closing `}` start in column 0, so we can detect block
# boundaries without a full parser.
pae_pub_fn_names() {
    local root="$1"
    [ -d "$root" ] || return 0
    find "$root" -type f -name '*.rs' -exec awk '
        BEGIN { in_pae = 0 }
        /^impl PlatformAppEngine \{/  { in_pae = 1; next }
        /^impl / && in_pae            { in_pae = 0 }
        /^\}/ && in_pae               { in_pae = 0; next }
        in_pae && /^[[:space:]]+pub fn / {
            line = $0
            sub(/^[[:space:]]+pub fn /, "", line)
            sub(/[(<].*$/, "", line)
            print line
        }
    ' {} + 2>/dev/null
}

# ── repo-relative paths ──────────────────────────────────────────────
CORE_PLATFORM_SRC="$WORKSPACE_ROOT/core/vauchi-platform/src"
CORE_CORE_SRC="$WORKSPACE_ROOT/core/vauchi-core/src"
IOS_SRC="$WORKSPACE_ROOT/ios/Vauchi"
MACOS_SRC="$WORKSPACE_ROOT/macos/Vauchi"
ANDROID_UI="$WORKSPACE_ROOT/android/app/src/main/kotlin/app/vauchi/ui"
TUI_STATE="$WORKSPACE_ROOT/tui/src/app/state.rs"

# ── counters ─────────────────────────────────────────────────────────

# 1. mobile_*.rs — uniffi export lines (each #[uniffi::export] attribute).
mobile_uniffi_exports=$(count_files_matching 'mobile_*.rs' \
    '^#\[uniffi::export' "$CORE_PLATFORM_SRC")

# 2. mobile_*.rs — pub fn lines (indented, inside impl blocks).
mobile_pub_fns=$(count_files_matching 'mobile_*.rs' \
    '^[[:space:]]+pub fn ' "$CORE_PLATFORM_SRC")

# 3. lib.rs — pub fns whose signature mentions MobileError or returns
#    Mobile* (the legacy free-function surface that routes back to
#    mobile_*.rs types).
if [ -f "$CORE_PLATFORM_SRC/lib.rs" ]; then
    lib_rs_mobile_returns=$(grep -cE '^[[:space:]]*pub fn .*(MobileError|-> *Mobile)' \
        "$CORE_PLATFORM_SRC/lib.rs" || true)
else
    lib_rs_mobile_returns=0
fi

# 4. PlatformAppEngine — total pub fns and the non-Humble subset.
pae_total=0
pae_non_humble=0
if [ -d "$CORE_PLATFORM_SRC" ]; then
    pae_names_tmp=$(mktemp)
    pae_pub_fn_names "$CORE_PLATFORM_SRC" >"$pae_names_tmp"
    pae_total=$(wc -l <"$pae_names_tmp" | awk '{print $1}')
    # Non-Humble = total minus matches against allowlist (exact-line).
    if [ "$pae_total" -gt 0 ]; then
        allowlist_tmp=$(mktemp)
        printf '%s\n' "$PAE_ALLOWLIST" >"$allowlist_tmp"
        # -F: fixed strings, -x: whole-line match, -v: invert.
        # `grep -Fxvc`: count of lines in $pae_names_tmp NOT matching
        # any allow-list entry. Exit code 1 (no matches → surplus is
        # zero) is also valid output, so `|| true` swallows it under
        # `set -e`.
        pae_non_humble=$(grep -Fxvc -f "$allowlist_tmp" "$pae_names_tmp" || true)
        rm -f "$allowlist_tmp"
    fi
    rm -f "$pae_names_tmp"
fi

# 5. iOS — `import VauchiPlatform` occurrences (file-count proxy for
#    "binding still reached for in Swift").
ios_vauchi_platform_imports=$(count_lines_matching \
    '^import VauchiPlatform' "$IOS_SRC")

# 6. iOS — Mobile* type-name references in *hand-written* Swift files
#    (every line that references a `Mobile[A-Z]…` identifier). Excludes
#    `Generated/` (UniFFI-emitted binding mirrors) and `Libs/` (the local
#    SPM checkout of `vauchi-platform-swift`); both are binding-
#    distribution artefacts that auto-shrink when Phase 3 retires
#    `mobile_*.rs` and are not the iOS team's responsibility to retire.
#    Counting them would mask the hand-written debt the Phase 4a /
#    Task 4a.3 lint flip is supposed to detect.
ios_mobile_type_refs=0
if [ -d "$IOS_SRC" ]; then
    ios_mobile_type_refs=$(grep -rsE '\bMobile[A-Z]' "$IOS_SRC" 2>/dev/null \
        | grep -v '/Generated/' \
        | grep -cv '/Libs/')
fi

# 7. Android — Mobile* references under the UI tree.
android_mobile_refs=$(count_lines_matching \
    '\bMobile[A-Z]' "$ANDROID_UI")

# 7b. macOS — Mobile* type-name references in *hand-written* Swift files
#     (Phase 6 / Task 6.1 ratchet). Same exclusions as iOS — `Generated/`
#     UniFFI mirror and `Libs/` local SPM checkout are
#     binding-distribution artefacts, not the macOS team's debt.
macos_mobile_refs=0
if [ -d "$MACOS_SRC" ]; then
    macos_mobile_refs=$(grep -rsE '\bMobile[A-Z]' "$MACOS_SRC" 2>/dev/null \
        | grep -v '/Generated/' \
        | grep -cv '/Libs/')
fi

# 8. TUI — variants of the legacy `enum Screen`. Each variant line is
#    Capitalised and the block lives in tui/src/app/state.rs.
tui_screen_variants=0
if [ -f "$TUI_STATE" ]; then
    tui_screen_variants=$(awk '
        /^pub enum Screen[ {<]/ { in_enum = 1; next }
        in_enum && /^\}/        { in_enum = 0; exit }
        in_enum && /^[[:space:]]+[A-Z]/ { count++ }
        END { print count + 0 }
    ' "$TUI_STATE")
fi

# 9–12. core/vauchi-core/src — ambient nondeterminism.
core_system_time_now=$(count_lines_matching \
    'SystemTime::now\(\)' "$CORE_CORE_SRC")
core_thread_rng=$(count_lines_matching \
    'thread_rng\(\)' "$CORE_CORE_SRC")
core_thread_sleep=0
if [ -d "$CORE_CORE_SRC" ]; then
    # Exclude `sleeper.rs` — it is the seam's own definition file. Its
    # `SystemSleeper` impl line and doc-comment references to
    # `std::thread::sleep` are intrinsic to the seam, not ambient debt.
    # Phase 1 / Task 1.3 introduced the file 2026-05-15; same precedent
    # as the iOS `Generated/` exclusion.
    # `|| true` so `set -euo pipefail` doesn't abort on the terminal
    # state `core_thread_sleep=0`: with zero matches, the first
    # `grep` exits 1 (BSD + GNU + BusyBox agree), `grep -cv` reads
    # empty stdin and prints "0" but also exits 1 (no non-matches),
    # `pipefail` surfaces that, and `set -e` kills the script on
    # this assignment. The `0` printed is correct; we just need to
    # swallow the upstream exit code. SC2126-compliant (sibling
    # iOS/macOS counters use the same `grep -cv` shape).
    core_thread_sleep=$(grep -rsE 'thread::sleep' "$CORE_CORE_SRC" 2>/dev/null \
        | grep -cv '/sleeper\.rs:' || true)
fi
# `crate::clock::ambient_now_secs` is the explicit transitional helper
# introduced in Phase 1 / Task 1.1 / Step 3a — every callsite is a
# TODO marker for the structural pass. Count all callsites of the
# wrapper itself (not its definition site in `clock.rs`); the helper
# returns 0 at end-state, at which point both `core_system_time_now`
# and `core_ambient_now_secs` are 0 simultaneously.
core_ambient_now_secs=$(count_lines_matching \
    'ambient_now_secs\(\)' "$CORE_CORE_SRC")

# ── timestamp (BSD + GNU + BusyBox safe) ─────────────────────────────
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── emit JSON ─────────────────────────────────────────────────────────
# Plain printf — no jq dependency. All values are integers, so no
# escaping is needed. Keys padded to a common column (36) so diffs
# across snapshots line up cleanly. The last entry omits its trailing
# comma; the test suite parses the output through `python3 -m json.tool`
# as a safety net.
printf '{\n'
printf '  "schema_version": 1,\n'
printf '  "captured_at": "%s",\n' "$captured_at"
printf '  "workspace_root": "%s",\n' "$WORKSPACE_ROOT"
printf '  "totals": {\n'
printf '    %-36s %d,\n' '"mobile_uniffi_exports":'             "$mobile_uniffi_exports"
printf '    %-36s %d,\n' '"mobile_pub_fns":'                    "$mobile_pub_fns"
printf '    %-36s %d,\n' '"lib_rs_mobile_returns":'             "$lib_rs_mobile_returns"
printf '    %-36s %d,\n' '"platform_app_engine_pub_fns_total":' "$pae_total"
printf '    %-36s %d,\n' '"platform_app_engine_non_humble":'    "$pae_non_humble"
printf '    %-36s %d,\n' '"ios_vauchi_platform_imports":'       "$ios_vauchi_platform_imports"
printf '    %-36s %d,\n' '"ios_mobile_type_refs":'              "$ios_mobile_type_refs"
printf '    %-36s %d,\n' '"android_mobile_refs":'               "$android_mobile_refs"
printf '    %-36s %d,\n' '"macos_mobile_refs":'                 "$macos_mobile_refs"
printf '    %-36s %d,\n' '"tui_screen_variants":'               "$tui_screen_variants"
printf '    %-36s %d,\n' '"core_system_time_now":'              "$core_system_time_now"
printf '    %-36s %d,\n' '"core_thread_rng":'                   "$core_thread_rng"
printf '    %-36s %d,\n' '"core_thread_sleep":'                 "$core_thread_sleep"
printf '    %-36s %d\n'  '"core_ambient_now_secs":'             "$core_ambient_now_secs"
printf '  }\n'
printf '}\n'
