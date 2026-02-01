#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Locale validation and sync tool for Vauchi i18n.
#
# Validates that all locale JSON files have the same keys as the English
# source of truth. Reports missing and extra keys per locale.
#
# Usage:
#   ./scripts/scripts/sync-locales.sh           # Validate all locales
#   ./scripts/scripts/sync-locales.sh --strict   # Exit with error if any issues found
#
# Requires: jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCALES_DIR="$ROOT_DIR/locales"
SOURCE_LOCALE="en"
STRICT=false

if [[ "${1:-}" == "--strict" ]]; then
    STRICT=true
fi

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required but not installed."
    echo "Install with: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
fi

SOURCE_FILE="$LOCALES_DIR/$SOURCE_LOCALE.json"

if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "ERROR: Source locale file not found: $SOURCE_FILE"
    exit 1
fi

# Extract string keys from a locale file (excludes _meta)
get_keys() {
    jq -r 'keys[] | select(startswith("_meta") | not)' "$1" | sort
}

# Get source keys
SOURCE_KEYS=$(get_keys "$SOURCE_FILE")
SOURCE_COUNT=$(echo "$SOURCE_KEYS" | wc -l | tr -d ' ')

echo "=== Vauchi Locale Validation ==="
echo ""
echo "Source: $SOURCE_LOCALE.json ($SOURCE_COUNT keys)"
echo ""

ERRORS=0

for locale_file in "$LOCALES_DIR"/*.json; do
    locale_name=$(basename "$locale_file" .json)

    # Skip source locale
    if [[ "$locale_name" == "$SOURCE_LOCALE" ]]; then
        continue
    fi

    TARGET_KEYS=$(get_keys "$locale_file")
    TARGET_COUNT=$(echo "$TARGET_KEYS" | wc -l | tr -d ' ')

    # Find missing keys (in source but not in target)
    MISSING=$(comm -23 <(echo "$SOURCE_KEYS") <(echo "$TARGET_KEYS"))
    MISSING_COUNT=$(echo "$MISSING" | grep -c . || true)

    # Find extra keys (in target but not in source)
    EXTRA=$(comm -13 <(echo "$SOURCE_KEYS") <(echo "$TARGET_KEYS"))
    EXTRA_COUNT=$(echo "$EXTRA" | grep -c . || true)

    if [[ "$MISSING_COUNT" -eq 0 ]] && [[ "$EXTRA_COUNT" -eq 0 ]]; then
        echo "  $locale_name.json: OK ($TARGET_COUNT/$SOURCE_COUNT keys)"
    else
        echo "  $locale_name.json: ISSUES ($TARGET_COUNT/$SOURCE_COUNT keys)"

        if [[ "$MISSING_COUNT" -gt 0 ]]; then
            echo "    Missing $MISSING_COUNT key(s):"
            echo "$MISSING" | while read -r key; do
                echo "      - $key"
            done
            ERRORS=$((ERRORS + MISSING_COUNT))
        fi

        if [[ "$EXTRA_COUNT" -gt 0 ]]; then
            echo "    Extra $EXTRA_COUNT key(s):"
            echo "$EXTRA" | while read -r key; do
                echo "      - $key"
            done
            ERRORS=$((ERRORS + EXTRA_COUNT))
        fi
    fi
done

echo ""

# Check for empty values
EMPTY_VALUES=0
for locale_file in "$LOCALES_DIR"/*.json; do
    locale_name=$(basename "$locale_file" .json)
    EMPTY=$(jq -r 'to_entries[] | select(.key != "_meta" and (.value | type) == "string" and .value == "") | .key' "$locale_file")
    if [[ -n "$EMPTY" ]]; then
        echo "  $locale_name.json: Empty values:"
        echo "$EMPTY" | while read -r key; do
            echo "    - $key"
            EMPTY_VALUES=$((EMPTY_VALUES + 1))
        done
    fi
done

if [[ "$ERRORS" -eq 0 ]] && [[ "$EMPTY_VALUES" -eq 0 ]]; then
    echo "All locales are complete and consistent."
    exit 0
else
    echo "Found $ERRORS key issue(s) and $EMPTY_VALUES empty value(s)."
    if $STRICT; then
        exit 1
    fi
    exit 0
fi
