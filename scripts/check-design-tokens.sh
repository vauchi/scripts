#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-design-tokens.sh — Warn about hardcoded design values that
# should use generated tokens.
#
# Usage:
#   check-design-tokens.sh <directory> [<directory> ...]
#   check-design-tokens.sh --strict <directory> ...
#   check-design-tokens.sh --strict-categories=<C1>[,<C2>...] <directory> ...
#
# Default: exits 0 (warning gate, for repos with non-zero baselines).
# --strict: exits 1 if ANY violation is found (blocking gate, fully clean
# baseline).
# --strict-categories=X,Y: exits 1 only if a violation tagged X or Y is
# found. Useful when one category is clean but another still has baseline
# hits that the team hasn't triaged yet (e.g. --strict-categories=RUST_RGB
# blocks raw Cairo RGB regressions while RUST_EN_STR stays advisory).
#
# Categories: SPACING, RADIUS, COLOR, DP, RUST_RGB, RUST_EN_STR, CPP_HEX,
# CPP_NAMED, CS_NAMED, CS_ARGB, CS_HEX.

set -euo pipefail

STRICT=0
STRICT_CATEGORIES=""
while [ $# -ge 1 ]; do
    case "$1" in
        --strict)
            STRICT=1
            shift
            ;;
        --strict-categories=*)
            STRICT_CATEGORIES="${1#--strict-categories=}"
            shift
            ;;
        --help|-h)
            sed -n '3,24p' "$0"
            exit 0
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

if [ $# -lt 1 ]; then
    echo "Usage: $0 [--strict | --strict-categories=CAT[,...]] <directory> ..."
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

    # Rust (linux-gtk): hardcoded English user-visible strings inside
    # GTK builders — should route through i18n::get_string(locale, "key").
    # Scoped to widget methods that render text: label/title/placeholder_text.
    # Requires two letters and a lowercase letter so CSS class names
    # like "suggested-action" slip through (CSS is usually via
    # css_classes(...) anyway), the brand "Vauchi" is 6 chars so it
    # does match — allowlist it with an explicit `-v` filter below.
    find "$DIR" -name '*.rs' \
        -not -name 'i18n.rs' \
        -not -name '*_test.rs' \
        -not -path '*/tests/*' \
        -print0 | xargs -0 grep -nE '\.(label|title|placeholder_text)\(\s*"[A-Za-z][A-Za-z][A-Za-z .,!?'\''…-]*"' 2>/dev/null \
        | grep -vE '\.title\(\s*"Vauchi"\s*\)' \
        | sed 's/^/RUST_EN_STR /' >> "$TMPFILE" || true

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

    # C# (windows): named `Colors.Red` / `Colors.Blue` etc. outside the
    # token source of truth. WinUI exposes Microsoft.UI.Colors.* and
    # Windows.UI.Colors.* — both forms are flagged; use Tokens.cs or a
    # theme-derived accessor instead.
    find "$DIR" -name '*.cs' \
        -not -name 'Tokens.cs' \
        -not -name 'Theme*.cs' \
        -not -path '*/obj/*' \
        -not -path '*/bin/*' \
        -not -path '*/Generated/*' \
        -print0 | xargs -0 grep -nE '\bColors\.(Red|Green|Blue|Yellow|Orange|Gray|Grey|White|Black|Purple|Cyan|Magenta|DodgerBlue)\b' 2>/dev/null \
        | sed 's/^/CS_NAMED /' >> "$TMPFILE" || true

    # C# (windows): `Color.FromArgb(...)` with all-numeric args (hardcoded).
    # Calls taking a runtime r/g/b (e.g. from core data) look like
    # `FromArgb(255, r, g, b)` and are allowed — only flag when the
    # second arg is also a numeric literal, i.e. the whole color is hex.
    find "$DIR" -name '*.cs' \
        -not -name 'Tokens.cs' \
        -not -name 'Theme*.cs' \
        -not -path '*/obj/*' \
        -not -path '*/bin/*' \
        -not -path '*/Generated/*' \
        -print0 | xargs -0 grep -nE '\bColor\.FromArgb\(\s*(0x)?[0-9a-fA-F]+\s*,\s*(0x)?[0-9a-fA-F]+\b' 2>/dev/null \
        | sed 's/^/CS_ARGB /' >> "$TMPFILE" || true

    # C# (windows): hex-color string literals (e.g. "#4682B4") outside
    # the token source of truth — these should come from themes.json.
    find "$DIR" -name '*.cs' \
        -not -name 'Tokens.cs' \
        -not -name 'Theme*.cs' \
        -not -path '*/obj/*' \
        -not -path '*/bin/*' \
        -not -path '*/Generated/*' \
        -print0 | xargs -0 grep -nE '"#[0-9a-fA-F]{6}"' 2>/dev/null \
        | sed 's/^/CS_HEX /' >> "$TMPFILE" || true
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
    echo "                        and i18n::get_string(Locale::default(), \"key\") for UI text"
    echo "      C++ (linux-qt) → ThemeManager::styleForRole(ThemeRole::*) (see coreui/thememanager.h)"
    echo "      C# (windows) → Tokens.cs values or a theme-derived accessor"
    echo "Source of truth: themes/tokens.json"
fi

if [ "$STRICT" -eq 1 ] && [ "$TOTAL" -gt 0 ]; then
    echo "FAIL: --strict mode, $TOTAL hardcoded value(s) found." >&2
    exit 1
fi

if [ -n "$STRICT_CATEGORIES" ]; then
    # Strict only for the requested categories; other violations stay advisory.
    STRICT_PATTERN=$(echo "$STRICT_CATEGORIES" | tr ',' '|')
    # Match: line starts with "<CATEGORY> " — anchor to the sed prefix above.
    STRICT_HITS=$(grep -cE "^(${STRICT_PATTERN}) " "$TMPFILE" || true)
    if [ "${STRICT_HITS:-0}" -gt 0 ]; then
        echo "FAIL: --strict-categories=${STRICT_CATEGORIES}, ${STRICT_HITS} blocking violation(s)." >&2
        exit 1
    fi
fi

# Warning gate — exit 0 even with violations
exit 0
