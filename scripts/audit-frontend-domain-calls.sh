#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# audit-frontend-domain-calls.sh — Humble-UI domain-mutation ratchet for
# the Rust / C++ / C# frontends (tui, cli, linux-gtk, linux-qt, windows).
#
# The sibling audit-frontend-vocab.sh ratchets the *mobile* (Swift/Kotlin)
# navigation-vocabulary deny-list; check-no-domain-conditionals-in-views.sh
# et al. gate android/ios/macos only. The Rust TUI/CLI and the C++/C#
# desktop frontends had ZERO automated Humble-UI coverage, so domain logic
# (validation, domain-type construction, settings mutation) could re-enter
# them with nothing in CI to catch it. This script closes that gap.
#
# Enforces: ADR-021 / ADR-043 (Humble UI — frontends are pure renderers;
#           business logic lives in core). A frontend that constructs
#           vauchi_core::types or calls a domain-mutating verb
#           (save_*/configure_*/setup_*/validate_*) is doing core's job.
#
# Origin record:
#   _private/docs/problems/2026-06-02-humble-ui-enforcement-mobile-only/
#
# SCOPE — counts ONE category per repo: handwritten frontend source lines
# containing a domain-mutating call, tuned per language:
#   Rust  (tui, cli, linux-gtk): a `.save_/configure_/setup_/validate_…(`
#         method call OR a `vauchi_core::types::` construction.
#   C++   (linux-qt): a `save/configure/setup/validate…(` call.
#   C#    (windows):  a `Save/Configure/Setup/Validate…(` call.
#
# Ratchet semantics (identical to audit-frontend-vocab.sh): the baseline
# is the current, non-zero count. A count ABOVE baseline fails CI; a count
# at or below passes. Lower the baseline on every retirement MR. Read
# queries (`is_*`, `list_*`, `get_*`, `load_*`) are deliberately NOT
# counted — Rust-native frontends legitimately call those (ADR-030: core
# owns logic, but frontends may *read*). The mutating-verb list is curated
# and starts loose; tighten it as the counts ratchet to 0.
#
# Usage:
#   audit-frontend-domain-calls.sh [workspace_root]
#       Emit the JSON snapshot on stdout (exit 0; exit 2 on internal error).
#   audit-frontend-domain-calls.sh --check <baseline.json> [workspace_root]
#       Ratchet mode. Exit 1 if ANY total EXCEEDS its baseline; else exit 0.
#
# Default workspace_root: two levels up from this script.
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
        printf 'audit-frontend-domain-calls: --check requires a baseline file\n' >&2
        exit 2
    fi
    if [ ! -f "$BASELINE_FILE" ]; then
        printf 'audit-frontend-domain-calls: baseline %s not found\n' "$BASELINE_FILE" >&2
        exit 2
    fi
    shift 2
fi

# ── locate workspace root ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="${1:-$DEFAULT_ROOT}"

if [ ! -d "$WORKSPACE_ROOT" ]; then
    printf 'audit-frontend-domain-calls: workspace_root %s is not a directory\n' \
        "$WORKSPACE_ROOT" >&2
    exit 2
fi
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"

# ── per-language detection regexes (POSIX ERE, no -P, no \b) ──────────
# Rust: a domain-mutating method call OR a core domain-type construction.
# The leading `\.` keeps free functions and locals (`let save_path = …`)
# out; the verb list is the curated mutating set from the origin record.
RUST_RE='(\.(save|configure|setup|validate)_[a-z_]+\()|(vauchi_core::types::)'
# C++/C# have no access to vauchi_core::types (they cross the C ABI, which
# is already the humble boundary), so the meaningful leak is a domain-verb
# call in handler code. `(^|[^A-Za-z0-9_])` is a portable word-start guard
# (BusyBox grep has no \b) so `autosave(` does not match `save(`.
CPP_RE='(^|[^A-Za-z0-9_])(save|configure|setup|validate)[A-Za-z_]*\('
CS_RE='(^|[^A-Za-z0-9_])(Save|Configure|Setup|Validate)[A-Za-z]*\('

# VRS02 (ADR-043): frontends never BRANCH on form factor. Comparing or
# matching on DisplayHint is the violation; passing DisplayHint::X as an
# engine-constructor argument is the sanctioned use and must not count.
# Curated-loose like the mutating-verb list; reversed-operand compares
# (DisplayHint::X == hint) are not matched yet — tighten as counts hit 0.
# Page: _private/docs/lint-errors/vrs02-form-factor-branches.md
RUST_FF_RE='(==|!=)[[:space:]]*DisplayHint::|matches!\([^)]*DisplayHint|match[[:space:]]+[A-Za-z_.]*display_hint'
CPP_FF_RE='(==|!=)[[:space:]]*(DisplayHint::|DISPLAY_HINT_)|display_hint[[:space:]]*(==|!=)|switch[[:space:]]*\([^)]*display_hint'
CS_FF_RE='(==|!=)[[:space:]]*DisplayHint\.|DisplayHint\.[A-Za-z]+[[:space:]]*(==|!=)|switch[[:space:]]*\([^)]*DisplayHint'

# ── exclusion filter ─────────────────────────────────────────────────
# Drop build output, vendored deps, generated bindings, and test trees so
# the baseline does not churn on test edits. Applied as a grep -v chain on
# the `path:lineno:line` output (BusyBox-safe — no --exclude).
strip_excluded() {
    grep -v '/target/' \
        | grep -v '/build/' \
        | grep -v '/build-test/' \
        | grep -v '/node_modules/' \
        | grep -v '/Generated/' \
        | grep -v '/local-bindings/' \
        | grep -v '/tests/' \
        | grep -v '/Tests/' \
        | grep -v '/test-automation/' \
        || true
}

# ── core counter ──────────────────────────────────────────────────────
# count_calls <src_root> <ext_path_re> <content_re>
# Recursively grep <content_re>, keep only lines whose path matches
# <ext_path_re> (e.g. '\.rs:'), drop excluded trees, count matching lines.
# Missing root → 0 (a frontend tree may be absent in single-repo CI).
count_calls() {
    root="$1"; ext_re="$2"; content_re="$3"
    [ -d "$root" ] || { printf '0'; return; }
    n=$(grep -rsnE "$content_re" "$root" 2>/dev/null \
        | grep -E "$ext_re" \
        | strip_excluded \
        | wc -l | tr -d '[:space:]')
    printf '%s' "${n:-0}"
}

# ── repo-relative frontend source roots ──────────────────────────────
TUI_SRC="$WORKSPACE_ROOT/tui/src"
CLI_SRC="$WORKSPACE_ROOT/cli/src"
GTK_SRC="$WORKSPACE_ROOT/linux-gtk/src"
QT_SRC="$WORKSPACE_ROOT/linux-qt/src"
WIN_SRC="$WORKSPACE_ROOT/windows/Vauchi"

# ── counters ─────────────────────────────────────────────────────────
domain_calls_tui=$(count_calls "$TUI_SRC" '\.rs:' "$RUST_RE")
domain_calls_cli=$(count_calls "$CLI_SRC" '\.rs:' "$RUST_RE")
domain_calls_linux_gtk=$(count_calls "$GTK_SRC" '\.rs:' "$RUST_RE")
domain_calls_linux_qt=$(count_calls "$QT_SRC" '\.(cpp|cc|h|hpp):' "$CPP_RE")
domain_calls_windows=$(count_calls "$WIN_SRC" '\.cs:' "$CS_RE")
domain_calls_total=$((domain_calls_tui + domain_calls_cli \
    + domain_calls_linux_gtk + domain_calls_linux_qt + domain_calls_windows))

form_factor_tui=$(count_calls "$TUI_SRC" '\.rs:' "$RUST_FF_RE")
form_factor_cli=$(count_calls "$CLI_SRC" '\.rs:' "$RUST_FF_RE")
form_factor_linux_gtk=$(count_calls "$GTK_SRC" '\.rs:' "$RUST_FF_RE")
form_factor_linux_qt=$(count_calls "$QT_SRC" '\.(cpp|cc|h|hpp):' "$CPP_FF_RE")
form_factor_windows=$(count_calls "$WIN_SRC" '\.cs:' "$CS_FF_RE")
form_factor_total=$((form_factor_tui + form_factor_cli \
    + form_factor_linux_gtk + form_factor_linux_qt + form_factor_windows))

# ── timestamp (BSD + GNU + BusyBox safe) ─────────────────────────────
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── render JSON ───────────────────────────────────────────────────────
emit_json() {
    printf '{\n'
    printf '  "schema_version": 2,\n'
    printf '  "captured_at": "%s",\n' "$captured_at"
    printf '  "workspace_root": "%s",\n' "$WORKSPACE_ROOT"
    printf '  "totals": {\n'
    printf '    %-30s %d,\n' '"domain_calls_tui":'        "$domain_calls_tui"
    printf '    %-30s %d,\n' '"domain_calls_cli":'        "$domain_calls_cli"
    printf '    %-30s %d,\n' '"domain_calls_linux_gtk":'  "$domain_calls_linux_gtk"
    printf '    %-30s %d,\n' '"domain_calls_linux_qt":'   "$domain_calls_linux_qt"
    printf '    %-30s %d,\n' '"domain_calls_windows":'    "$domain_calls_windows"
    printf '    %-30s %d,\n' '"domain_calls_total":'      "$domain_calls_total"
    printf '    %-30s %d,\n' '"form_factor_tui":'         "$form_factor_tui"
    printf '    %-30s %d,\n' '"form_factor_cli":'         "$form_factor_cli"
    printf '    %-30s %d,\n' '"form_factor_linux_gtk":'   "$form_factor_linux_gtk"
    printf '    %-30s %d,\n' '"form_factor_linux_qt":'    "$form_factor_linux_qt"
    printf '    %-30s %d,\n' '"form_factor_windows":'     "$form_factor_windows"
    printf '    %-30s %d\n'  '"form_factor_total":'       "$form_factor_total"
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
        printf 'REGRESSION %s: baseline %d, now %d (domain-call count must not rise)\n' \
            "$name" "$base" "$current" >&2
        regressions=$((regressions + 1))
    fi
}

check_one 'domain_calls_tui'       "$domain_calls_tui"
check_one 'domain_calls_cli'       "$domain_calls_cli"
check_one 'domain_calls_linux_gtk' "$domain_calls_linux_gtk"
check_one 'domain_calls_linux_qt'  "$domain_calls_linux_qt"
check_one 'domain_calls_windows'   "$domain_calls_windows"
check_one 'domain_calls_total'     "$domain_calls_total"

check_one 'form_factor_tui'        "$form_factor_tui"
check_one 'form_factor_cli'        "$form_factor_cli"
check_one 'form_factor_linux_gtk'  "$form_factor_linux_gtk"
check_one 'form_factor_linux_qt'   "$form_factor_linux_qt"
check_one 'form_factor_windows'    "$form_factor_windows"
check_one 'form_factor_total'      "$form_factor_total"

if [ "$regressions" -gt 0 ]; then
    printf 'audit-frontend-domain-calls: %d counter(s) exceeded baseline %s\n' \
        "$regressions" "$BASELINE_FILE" >&2
    printf 'A frontend must not grow domain logic. Move the call into a core\n' >&2
    printf 'engine (ADR-021/043). If a count legitimately dropped, ratchet the\n' >&2
    printf 'baseline DOWN to match.\n' >&2
    exit 1
fi

printf 'audit-frontend-domain-calls: OK — all totals at or below baseline %s\n' \
    "$BASELINE_FILE"
exit 0
