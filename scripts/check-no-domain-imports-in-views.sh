#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-no-domain-imports-in-views.sh — Forbid `Mobile*` domain-type
# imports and identity/biometric conditionals in the Android view layer.
#
# Usage: check-no-domain-imports-in-views.sh <root> [--strict]
#
# <root> may be the multi-repo workspace root (expects `android/app/…`)
# or a single-repo android checkout root (expects `app/…`). Both
# layouts are resolved; when neither tree exists the script no-ops
# (repos without an android tree).
#
# Default mode is **warn-only** — violations print to stdout with a
# WARN prefix and the script exits 0. Pass `--strict` to exit 1 on
# violations (error mode).
#
# This is the Phase-1 lint guard for problem
# `2026-05-01-android-humble-ui-deep-retirement`. It fences off new
# `Mobile*` imports and identity/biometric branches landing in the
# view layer. Phase 4.6 closed 2026-06-08 (the MainViewModel diet
# landed, 1,881 → 537 LOC) and flipped the wiring to `--strict` — new
# `Mobile*` imports in view Composables now fail CI, not just warn.
#
# Allowlist:
#   - `app/src/main/kotlin/app/vauchi/ui/coreui/` — generic
#     `Component` renderers; the legitimate FFI boundary.
#   - `app/src/main/kotlin/app/vauchi/ui/MainViewModel.kt` — the app
#     shell ViewModel; holds shell-state `Mobile*` types
#     (`MobileContactCard` on `UiState.Ready`, `MobileSyncResult`,
#     `MobileEvent`, `MobileException`), not domain-CRUD wrappers.
#   - `app/src/main/kotlin/app/vauchi/ui/MainActivity.kt` — app
#     entrypoint, may need bootstrap-time domain refs.
#   - `app/src/main/kotlin/app/vauchi/ui/theme/Theme.kt` — reads
#     `MobileTheme.colors.*` design tokens to build the Material3
#     `ColorScheme`. ADR-038 mandates reading tokens from the
#     core/UniFFI surface; `MobileTheme` *is* that surface, so this is
#     a sanctioned token read, not a domain leak.
#
# Patterns flagged outside the allowlist:
#   - `import uniffi.vauchi_platform.Mobile[A-Z]` (Mobile* type import)
#   - `repository\.hasIdentity\(\)` (identity conditional)
#   - `MobileBiometricUnlockOutcome` (biometric outcome enum)
#
# The complementary G5 lint
# (`check-no-domain-conditionals-in-views.sh`) covers a different
# class — field-level predicate reads (`.isVerified`, `.trustLevel`,
# etc.). The two scripts are deliberately separate; one fences
# imports/branches, the other fences predicates.

# VAUCHI_ANDROID_DISPLAY_ROOT declares an additional required library checkout.
set -euo pipefail

# Guard fails LOUD without ripgrep: `rg … || true` silently reported
# clean wherever rg was missing (both CI runner flavors) — a guard
# that self-disables is worse than none.
if ! command -v rg >/dev/null 2>&1; then
    echo "ERROR: ripgrep (rg) is required by $(basename "$0") — install it (apt/brew/apk add ripgrep)" >&2
    exit 2
fi

STRICT=0
WORKSPACE_ROOT=""

for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        --help|-h)
            sed -n '8,32p' "$0" | sed 's/^# //;s/^#//'
            exit 0
            ;;
        -*)
            echo "Unknown flag: $arg" >&2
            exit 2
            ;;
        *)
            if [ -z "$WORKSPACE_ROOT" ]; then
                WORKSPACE_ROOT="$arg"
            else
                echo "Unexpected argument: $arg" >&2
                exit 2
            fi
            ;;
    esac
done

if [ -z "$WORKSPACE_ROOT" ]; then
    echo "Usage: $0 <workspace_root> [--strict]" >&2
    exit 2
fi

if [ ! -d "$WORKSPACE_ROOT" ]; then
    echo "Error: $WORKSPACE_ROOT is not a directory" >&2
    exit 2
fi

ANDROID_UI="$WORKSPACE_ROOT/android/app/src/main/kotlin/app/vauchi/ui"

if [ ! -d "$ANDROID_UI" ] && [ -d "$WORKSPACE_ROOT/app/src/main/kotlin/app/vauchi/ui" ]; then
    # Single-repo (android) checkout layout — repo root passed directly.
    ANDROID_UI="$WORKSPACE_ROOT/app/src/main/kotlin/app/vauchi/ui"
fi

ANDROID_DISPLAY_UI="$WORKSPACE_ROOT/android/display/src/main/kotlin/app/vauchi/ui"
[ -d "$ANDROID_DISPLAY_UI" ] || ANDROID_DISPLAY_UI="$WORKSPACE_ROOT/display/src/main/kotlin/app/vauchi/ui"
ANDROID_SETTINGS="$WORKSPACE_ROOT/android/settings.gradle.kts"
[ -f "$ANDROID_SETTINGS" ] || ANDROID_SETTINGS="$WORKSPACE_ROOT/settings.gradle.kts"
if [ -f "$ANDROID_SETTINGS" ]; then
    display_settings=$(sed 's,//.*$,,' "$ANDROID_SETTINGS")
    if [[ "$display_settings" == *'":display"'* ]]; then
        if ! display_inventory=$(rg --files --glob '*.kt' --glob '*.java' "$ANDROID_DISPLAY_UI") || [ -z "$display_inventory" ]; then
            echo "ERROR: declared display module has no readable view sources: $ANDROID_DISPLAY_UI" >&2
            exit 2
        fi
    fi
fi

ANDROID_INDEPENDENT_DISPLAY_UI=""
independent_module=""
if [ "${VAUCHI_ANDROID_DISPLAY_ROOT+x}" = x ]; then
    independent_module="$VAUCHI_ANDROID_DISPLAY_ROOT"
elif [ -e "$WORKSPACE_ROOT/android-display" ] || [ -L "$WORKSPACE_ROOT/android-display" ]; then
    independent_module="$WORKSPACE_ROOT/android-display"
elif [ -d "$WORKSPACE_ROOT/src" ]; then
    independent_module="$WORKSPACE_ROOT"
fi
if [ -n "$independent_module" ] || [ "${VAUCHI_ANDROID_DISPLAY_ROOT+x}" = x ]; then
    ANDROID_INDEPENDENT_DISPLAY_UI="$independent_module/src/main/kotlin/app/vauchi/ui"
    if [ -z "$independent_module" ] || [ -L "$independent_module" ] || [ -L "$independent_module/src" ] || [ ! -d "$independent_module/src" ]; then
        echo "ERROR: independent display module has no regular source root: $independent_module" >&2
        exit 2
    fi
    if ! linked_sources=$(find "$independent_module/src" -type l) || [ -n "$linked_sources" ]; then
        echo "ERROR: independent display source tree contains links or cannot be inspected: $independent_module" >&2
        exit 2
    fi
    if ! display_inventory=$(rg --files --hidden --no-ignore --glob '*.kt' --glob '*.java' "$ANDROID_INDEPENDENT_DISPLAY_UI") || [ -z "$display_inventory" ]; then
        echo "ERROR: independent display module has no readable view sources: $ANDROID_INDEPENDENT_DISPLAY_UI" >&2
        exit 2
    fi
fi

if [ ! -d "$ANDROID_UI" ] && [ ! -d "$ANDROID_DISPLAY_UI" ] && [ ! -d "$ANDROID_INDEPENDENT_DISPLAY_UI" ]; then
    exit 0
fi

# Allowlisted paths — relative to ANDROID_UI.
ALLOWLIST_GLOBS=(
    'coreui/*'
    'MainViewModel.kt'
    'MainActivity.kt'
    'theme/Theme.kt'
)

# Each entry: pattern|description
PATTERNS=(
    'import uniffi\.vauchi_platform\.Mobile[A-Z]|Mobile* domain-type import — views render ScreenModel, not Mobile* types (ADR-021/043)'
    'repository\.hasIdentity\(\)|identity conditional in view — core emits unlock-or-onboard ScreenModel'
    'MobileBiometricUnlockOutcome|biometric outcome enum in view — core emits the routed ScreenModel'
)

VIOLATIONS=0
REPORT=""

is_allowlisted() {
    local rel="$1"
    for glob in "${ALLOWLIST_GLOBS[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$rel" == $glob ]]; then
            return 0
        fi
    done
    return 1
}

scan() {
    local pattern="$1"
    local description="$2"
    local dir="$3"
    local matches search_status
    # Searched from inside the tree: an absolute Windows path starts with
    # a drive letter and a colon, which the <path>:<line>:<text> split
    # below would cut at.
    if matches="$(cd "$dir" && rg --hidden --no-ignore --line-number --no-heading "$pattern" .)"; then
        :
    else
        search_status=$?
        if [ "$search_status" -ne 1 ]; then
            echo "ERROR: ripgrep could not complete the view scan: $dir" >&2
            return "$search_status"
        fi
    fi
    if [ -z "$matches" ]; then
        return 0
    fi
    local filtered=""
    while IFS= read -r line; do
        # rg output: ./<rel_path>:<lineno>:<text>, backslashes on Windows
        local rel="${line%%:*}"
        rel="${rel//\\//}"
        rel="${rel#./}"
        if [ "$dir" = "$ANDROID_UI" ] && is_allowlisted "$rel"; then
            continue
        fi
        filtered+="$dir/$rel:${line#*:}"$'\n'
    done <<<"$matches"
    if [ -n "$filtered" ]; then
        REPORT+=$'\n'"${description}:"$'\n'"$filtered"
        # Count non-empty lines.
        local n
        n="$(printf '%s' "$filtered" | grep -c .)"
        VIOLATIONS=$((VIOLATIONS + n))
    fi
}

for entry in "${PATTERNS[@]}"; do
    pattern="${entry%%|*}"
    description="${entry#*|}"
    for dir in "$ANDROID_UI" "$ANDROID_DISPLAY_UI" "$ANDROID_INDEPENDENT_DISPLAY_UI"; do
        if [ -d "$dir" ]; then scan "$pattern" "$description" "$dir"; fi
    done
done

if [ "$VIOLATIONS" -gt 0 ]; then
    if [ "$STRICT" -eq 1 ]; then
        prefix="FAIL"
        rc=1
    else
        prefix="WARN (warn-only — pass --strict to fail CI)"
        rc=0
    fi
    echo "${prefix}: view-layer Mobile* imports / identity branches (Phase 1 of 2026-05-01-android-humble-ui-deep-retirement):"
    echo "$REPORT"
    echo
    echo "View code must render ScreenModel only. Allowed FFI types:"
    echo "  ScreenModel, Component, UserAction, ExchangeCommand,"
    echo "  ExchangeHardwareEvent, DesignTokens."
    echo
    echo "Allowlisted paths (legitimate domain consumers):"
    for g in "${ALLOWLIST_GLOBS[@]}"; do
        echo "  ui/$g"
    done
    echo
    echo "See _private/docs/problems/2026-05-01-android-humble-ui-deep-retirement/."
    exit "$rc"
fi

echo "OK: no view-layer Mobile* imports or identity branches found"
exit 0
