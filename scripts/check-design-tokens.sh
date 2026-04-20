#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-design-tokens.sh — Warn about hardcoded design values that
# should use generated tokens.
#
# Usage: check-design-tokens.sh <directory> [<directory> ...]
# Example: check-design-tokens.sh ios/Vauchi/ android/app/src/
#
# Exits 0 always (warning only). Prints violations found.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <directory> [<directory> ...]"
    exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

for DIR in "$@"; do
    [ -d "$DIR" ] || continue

    # Swift: find off-scale .padding(N) values (not 4/8/16/24/32)
    # shellcheck disable=SC2016
    find "$DIR" -name '*.swift' \
        -not -path '*/Generated/*' \
        -not -name 'Tokens.swift' \
        -not -name 'ThemeService.swift' \
        -print0 | xargs -0 grep -nE '\.padding\([0-9]+\)' 2>/dev/null \
        | grep -vE '\.padding\((4|8|16|24|32)\)' \
        | sed 's/^/SPACING /' >> "$TMPFILE" || true

    # Swift: find off-scale .cornerRadius(N) (not 4/8/16)
    find "$DIR" -name '*.swift' \
        -not -path '*/Generated/*' \
        -print0 | xargs -0 grep -nE '\.cornerRadius\([0-9]+\)' 2>/dev/null \
        | grep -vE '\.cornerRadius\((4|8|16)\)' \
        | sed 's/^/RADIUS /' >> "$TMPFILE" || true

    # Swift: find hardcoded .tint(.cyan), .foregroundColor(.blue), etc.
    # These should use theme.accent, theme.success, etc.
    find "$DIR" -name '*.swift' \
        -not -path '*/Generated/*' \
        -not -name 'ThemeService.swift' \
        -print0 | xargs -0 grep -nE '\.(tint|foregroundColor|foregroundStyle)\(\.(cyan|blue|red|green|orange|yellow)\)' 2>/dev/null \
        | sed 's/^/COLOR /' >> "$TMPFILE" || true

    # Kotlin: find off-scale N.dp values (not 0/1/2/4/8/16/24/32/44)
    find "$DIR" -name '*.kt' \
        -not -name 'Tokens.kt' \
        -not -name 'Theme.kt' \
        -print0 | xargs -0 grep -nE '[0-9]+\.dp' 2>/dev/null \
        | grep -vE '(0|1|2|4|8|16|24|32|44)\.dp' \
        | sed 's/^/DP /' >> "$TMPFILE" || true

    # Rust (linux-gtk): raw Cairo set_source_rgb calls with numeric args.
    # Callers should destructure from a named constant (e.g., QR_MODULE_LIGHT)
    # so the intent is documented in one place. theme.rs is the token source.
    find "$DIR" -name '*.rs' \
        -not -name 'theme.rs' \
        -not -name '*_test.rs' \
        -not -path '*/tests/*' \
        -print0 | xargs -0 grep -nE 'set_source_rgb\(\s*[0-9]' 2>/dev/null \
        | sed 's/^/RUST_RGB /' >> "$TMPFILE" || true

    # C++ (linux-qt): hex-color literals inside setStyleSheet calls.
    # thememanager.* is the palette source of truth and is excluded.
    find "$DIR" \( -name '*.cpp' -o -name '*.cc' -o -name '*.cxx' -o -name '*.h' -o -name '*.hpp' \) \
        -not -name 'thememanager.*' \
        -not -path '*/tests/*' \
        -not -path '*/build/*' \
        -print0 | xargs -0 grep -nE 'setStyleSheet\([^)]*#[0-9a-fA-F]{3,8}' 2>/dev/null \
        | sed 's/^/CPP_HEX /' >> "$TMPFILE" || true

    # C++ (linux-qt): named CSS colors inside setStyleSheet calls.
    # Catches regressions like `setStyleSheet("color: red;")`.
    find "$DIR" \( -name '*.cpp' -o -name '*.cc' -o -name '*.cxx' -o -name '*.h' -o -name '*.hpp' \) \
        -not -name 'thememanager.*' \
        -not -path '*/tests/*' \
        -not -path '*/build/*' \
        -print0 | xargs -0 grep -nE 'setStyleSheet\([^)]*color:[[:space:]]*(red|green|blue|yellow|gray|grey|white|black|orange|purple|cyan|magenta)' 2>/dev/null \
        | sed 's/^/CPP_NAMED /' >> "$TMPFILE" || true
done

TOTAL=$(wc -l < "$TMPFILE" | tr -d ' ')

echo "=== Design Token Lint ==="
echo "Directories scanned: $*"
echo "Hardcoded values found: $TOTAL"

if [ "$TOTAL" -gt 0 ]; then
    echo ""
    head -30 "$TMPFILE"
    if [ "$TOTAL" -gt 30 ]; then
        echo "  ... and $((TOTAL - 30)) more"
    fi
    echo ""
    echo "WARN: Swift/Kotlin → Tokens.Spacing.md, Tokens.BorderRadius.sm, etc."
    echo "      Rust (linux-gtk) → named module-level consts or theme colors (see core_ui/theme.rs)"
    echo "      C++ (linux-qt) → ThemeManager::styleForRole(ThemeRole::*) (see coreui/thememanager.h)"
    echo "Source of truth: themes/tokens.json"
fi

# Always exit 0 — warning gate
exit 0
