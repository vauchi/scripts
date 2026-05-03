#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-no-domain-imports-in-views.sh — Forbid `Mobile*` domain-type
# imports and identity/biometric conditionals in the Android view layer.
#
# Usage: check-no-domain-imports-in-views.sh <workspace_root> [--strict]
#
# Default mode is **warn-only** — violations print to stdout with a
# WARN prefix and the script exits 0. Pass `--strict` to exit 1 on
# violations (error mode).
#
# This is the Phase-1 lint guard for problem
# `2026-05-01-android-humble-ui-deep-retirement`. It fences off new
# `Mobile*` imports and identity/biometric branches landing in the
# view layer while Phases 2–4 retire the existing ones. Phase 4.6
# flips the wiring from default (warn) to `--strict`.
#
# Allowlist:
#   - `app/src/main/kotlin/app/vauchi/ui/coreui/` — generic
#     `Component` renderers; the legitimate FFI boundary.
#   - `app/src/main/kotlin/app/vauchi/ui/MainViewModel.kt` — Phase-4
#     target; tolerated during Phases 2–3.
#   - `app/src/main/kotlin/app/vauchi/ui/MainActivity.kt` — app
#     entrypoint, may need bootstrap-time domain refs.
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

set -euo pipefail

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

if [ ! -d "$ANDROID_UI" ]; then
    # Not all repos checkouts include android/ — silent no-op.
    exit 0
fi

# Allowlisted paths — relative to ANDROID_UI.
ALLOWLIST_GLOBS=(
    'coreui/*'
    'MainViewModel.kt'
    'MainActivity.kt'
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
    local matches
    matches="$(rg --line-number --no-heading "$pattern" "$ANDROID_UI" 2>/dev/null || true)"
    if [ -z "$matches" ]; then
        return 0
    fi
    local filtered=""
    while IFS= read -r line; do
        # rg output: <abs_path>:<lineno>:<text>
        local abs="${line%%:*}"
        local rel="${abs#"$ANDROID_UI"/}"
        if is_allowlisted "$rel"; then
            continue
        fi
        filtered+="$line"$'\n'
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
    scan "$pattern" "$description"
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
