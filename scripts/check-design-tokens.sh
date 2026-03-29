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
    echo "WARN: Use Tokens.Spacing.md, Tokens.BorderRadius.sm, etc."
    echo "Source of truth: themes/tokens.json"
fi

# Always exit 0 — warning gate
exit 0
