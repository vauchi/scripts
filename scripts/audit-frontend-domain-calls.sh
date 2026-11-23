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
# the `path:lineno:line` output (BusyBox-safe — no --exclude). Rust inline
# `#[cfg(test)] mod tests` modules are the same category; they are dropped
# upstream in rust_source_lines (a grep -v cannot express "everything after
# the attribute in the same file").
# `_tests.rs` is excluded because the repo gates sibling test files with
# `#[cfg(test)]` on the `#[path] mod` declaration in the PARENT module.
# The attribute therefore lives in a different file than the code, and
# the cfg(test) state machine in rust_source_lines cannot see it — test
# arrangement would otherwise count as a frontend domain call.
strip_excluded() {
    grep -v '/target/' \
        | grep -v '/build/' \
        | grep -v '/build-test/' \
        | grep -v '/node_modules/' \
        | grep -v '/Generated/' \
        | grep -v '/local-bindings/' \
        | grep -v '/tests/' \
        | grep -v '/Tests/' \
        | grep -v '_tests\.rs:' \
        | grep -v '/test-automation/' \
        || true
}

# Native renderer artifact export is platform I/O, while
# `save_exchanged_contact` is an atomic core-owned domain operation. Neither
# contains frontend domain logic. SecureStorage writes, user-selected backup
# file writes, and window-geometry persistence are also platform adapters
# explicitly owned by the frontend under ADR-043. Keep exclusions API-specific:
# a blanket `save` exclusion would hide the mutations this audit exists to catch.
#
# `ConfigureRole` assigns one Core-prepared context-bar role to a native
# Button: it reads `label`, `enabled`, `interaction_id`, and
# `accessibility_label` straight off the command and sets them. It derives no
# copy, classifies no category, and makes no domain decision — the exact
# mapping ADR-066 sanctions. Only the `Configure` verb makes it look like
# domain logic.
strip_sanctioned_boundary_calls() {
    grep -vE '\.save_to_png_bytes\(' \
        | grep -vE '(^|[^A-Za-z0-9_])pixmap\.save\(' \
        | grep -vE '(^|[^A-Za-z0-9_])grab\(\)\.save\(' \
        | grep -vE '\.save_exchanged_contact\(' \
        | grep -vE '\.save_key\(' \
        | grep -vE '(^|[^A-Za-z0-9_])saveBackupToFile\(' \
        | grep -vE '(^|[^A-Za-z0-9_])SaveWindowState\(' \
        | grep -vE '(^|[^A-Za-z0-9_])ConfigureRole\(' \
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
    # A tree with no match is the normal case. Under sh, errexit and
    # pipefail reach into `$(...)`, so grep's exit 1 would end the audit.
    n=$({ grep -rsnE "$content_re" "$root" 2>/dev/null || true; } \
        | { grep -E "$ext_re" || true; } \
        | strip_excluded \
        | strip_sanctioned_boundary_calls \
        | wc -l | tr -d '[:space:]')
    printf '%s' "${n:-0}"
}

# rust_source_lines <src_root>
# Emit `path:lineno:line` for every line OUTSIDE inline test modules in
# each .rs file under <src_root>. The /tests/ tree exclusion keeps
# external fixtures out of the baseline; Rust's inline
# `#[cfg(test)] mod tests` idiom is the same category.
#
# The skip region opens ONLY on a column-0 `#[cfg(test)]` whose next
# non-attribute line declares a `mod` — a `#[cfg(test)] use …;` or an
# indented impl-level attribute is test-only *code*, not a module, and
# must not blind the production lines below it (both shapes exist in this
# workspace and silently dropped ~95% of cli/src/ui/presentation.rs from
# the audit under the looser heuristic). A `#[cfg(test)]` free function
# at column 0 keeps its own body counted (over-count direction, safe).
rust_source_lines() {
    root="$1"
    [ -d "$root" ] || return 0
    # FNR==1 resets the state machine per file, so one awk process can
    # safely chew the whole batch (find -exec +).
    find "$root" -type f -name '*.rs' -exec awk '
        FNR == 1 { in_tests = 0; pending = 0 }
        in_tests { next }
        pending && /^[[:space:]]*#/ {
            printf "%s:%d:%s\n", FILENAME, FNR, $0; next
        }
        pending && /^(pub(\([^)]*\))?[[:space:]]+)?mod[[:space:]]/ {
            in_tests = 1; pending = 0; next
        }
        pending { pending = 0; printf "%s:%d:%s\n", FILENAME, FNR, $0; next }
        /^#\[cfg\(test\)\]/ {
            pending = 1; printf "%s:%d:%s\n", FILENAME, FNR, $0; next
        }
        { printf "%s:%d:%s\n", FILENAME, FNR, $0 }
    ' {} +
}

# count_rust_calls <src_root> <content_re>
# Rust counterpart of count_calls: counts <content_re> over .rs source
# lines, skipping inline #[cfg(test)] modules and excluded trees.
count_rust_calls() {
    root="$1"; content_re="$2"
    [ -d "$root" ] || { printf '0'; return; }
    n=$(rust_source_lines "$root" \
        | { grep -E "$content_re" || true; } \
        | strip_excluded \
        | strip_sanctioned_boundary_calls \
        | wc -l | tr -d '[:space:]')
    printf '%s' "${n:-0}"
}

# ── repo-relative frontend source roots ──────────────────────────────
# cli and tui become cli-display and tui-display (private#1233); a
# checkout that has not followed is read under its old name.
CLI_DIR=cli-display
[ -d "$WORKSPACE_ROOT/cli-display" ] || [ ! -d "$WORKSPACE_ROOT/cli" ] || CLI_DIR=cli
TUI_DIR=tui-display
[ -d "$WORKSPACE_ROOT/tui-display" ] || [ ! -d "$WORKSPACE_ROOT/tui" ] || TUI_DIR=tui
TUI_SRC="$WORKSPACE_ROOT/$TUI_DIR/src"
CLI_SRC="$WORKSPACE_ROOT/$CLI_DIR/src"
# ADR-078 renamed linux-gtk and linux-qt (private#1029). A checkout that
# still has the old directory is read there; looking for one name only
# would count nothing in it and pass.
GTK_DIR=gtk-display
[ -d "$WORKSPACE_ROOT/gtk-display" ] || [ ! -d "$WORKSPACE_ROOT/linux-gtk" ] || GTK_DIR=linux-gtk
QT_DIR=qt-display
[ -d "$WORKSPACE_ROOT/qt-display" ] || [ ! -d "$WORKSPACE_ROOT/linux-qt" ] || QT_DIR=linux-qt
GTK_SRC="$WORKSPACE_ROOT/$GTK_DIR/src"
QT_SRC="$WORKSPACE_ROOT/$QT_DIR/src"
# windows was renamed to windows-app (private#1234); a checkout that has
# not followed is read under its old name.
WIN_DIR=windows-app
[ -d "$WORKSPACE_ROOT/windows-app" ] || [ ! -d "$WORKSPACE_ROOT/windows" ] || WIN_DIR=windows
WIN_SRC="$WORKSPACE_ROOT/$WIN_DIR/Vauchi"

# ── counters ─────────────────────────────────────────────────────────
domain_calls_tui=$(count_rust_calls "$TUI_SRC" "$RUST_RE")
domain_calls_cli=$(count_rust_calls "$CLI_SRC" "$RUST_RE")
domain_calls_linux_gtk=$(count_rust_calls "$GTK_SRC" "$RUST_RE")
domain_calls_linux_qt=$(count_calls "$QT_SRC" '\.(cpp|cc|h|hpp):' "$CPP_RE")
domain_calls_windows=$(count_calls "$WIN_SRC" '\.cs:' "$CS_RE")
domain_calls_total=$((domain_calls_tui + domain_calls_cli \
    + domain_calls_linux_gtk + domain_calls_linux_qt + domain_calls_windows))

form_factor_tui=$(count_rust_calls "$TUI_SRC" "$RUST_FF_RE")
form_factor_cli=$(count_rust_calls "$CLI_SRC" "$RUST_FF_RE")
form_factor_linux_gtk=$(count_rust_calls "$GTK_SRC" "$RUST_FF_RE")
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
read_key() {  # read_key <file> <key>
    [ -f "$1" ] || return 1
    awk -v k="\"$2\"" '
        $1 ~ k {
            v = $0
            sub(/.*:[[:space:]]+/, "", v)
            sub(/,$/, "", v)
            print v + 0
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$1"
}

# Counter names are `<metric>_<repo>`; the repo segment uses underscores
# where the directory uses hyphens.
repo_dir_for() {
    case "$1" in
        linux_gtk) echo 'linux-gtk' ;;
        linux_qt)  echo 'linux-qt' ;;
        *)         echo "$1" ;;
    esac
}

# A repo may declare its own budget in `<repo>/.audit-baseline.json`,
# keyed by bare metric name. That file lives in the repo it measures, so
# lowering it and removing the calls it counts is one atomic MR — the
# shared file cannot offer that (scripts!510 merged a lowering before the
# removal that earned it). Absent, the shared file still applies, so
# adopting this is per-repo and opt-in.
per_repo_baseline() {  # per_repo_baseline <metric> <repo>
    read_key "$WORKSPACE_ROOT/$(repo_dir_for "$2")/.audit-baseline.json" "$1"
}

baseline_value() {  # baseline_value <metric> <repo>
    if [ -n "${2:-}" ] && v=$(per_repo_baseline "$1" "$2"); then
        echo "$v"
        return 0
    fi
    if [ -n "${2:-}" ]; then
        shared_key="$1_$2"
    else
        shared_key="$1"
    fi
    read_key "$BASELINE_FILE" "$shared_key" || echo 0
}

regressions=0
summed_baseline=0
check_one() {  # check_one <metric> <repo> <current>
    metric="$1"
    repo="$2"
    current="$3"
    base=$(baseline_value "$metric" "$repo")
    base="${base:-0}"
    summed_baseline=$((summed_baseline + base))
    if [ "$current" -gt "$base" ]; then
        printf 'REGRESSION %s_%s: baseline %d, now %d (domain-call count must not rise)\n' \
            "$metric" "$repo" "$base" "$current" >&2
        regressions=$((regressions + 1))
    fi
}

# The aggregate is derived, never read: it must equal the sum of the
# budgets actually in force, or a permissive shared total would silently
# re-permit what a per-repo file forbids.
check_total() {  # check_total <metric> <current>
    if [ "$2" -gt "$summed_baseline" ]; then
        printf 'REGRESSION %s_total: baseline %d, now %d (domain-call count must not rise)\n' \
            "$1" "$summed_baseline" "$2" >&2
        regressions=$((regressions + 1))
    fi
}

summed_baseline=0
check_one 'domain_calls' tui       "$domain_calls_tui"
check_one 'domain_calls' cli       "$domain_calls_cli"
check_one 'domain_calls' linux_gtk "$domain_calls_linux_gtk"
check_one 'domain_calls' linux_qt  "$domain_calls_linux_qt"
check_one 'domain_calls' windows   "$domain_calls_windows"
check_total 'domain_calls'         "$domain_calls_total"

summed_baseline=0
check_one 'form_factor' tui        "$form_factor_tui"
check_one 'form_factor' cli        "$form_factor_cli"
check_one 'form_factor' linux_gtk  "$form_factor_linux_gtk"
check_one 'form_factor' linux_qt   "$form_factor_linux_qt"
check_one 'form_factor' windows    "$form_factor_windows"
check_total 'form_factor'          "$form_factor_total"

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
