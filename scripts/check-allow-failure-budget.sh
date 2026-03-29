#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-allow-failure-budget.sh — Fail if allow_failure: true count
# exceeds the budget across CI configs.
#
# Usage: check-allow-failure-budget.sh [--budget N] <path> [<path> ...]
# Example: check-allow-failure-budget.sh --budget 57 . ../core ../relay
#
# Scans .gitlab-ci.yml files and ci-templates/*.yml for
# allow_failure: true. Exits non-zero if count exceeds budget.
#
# Default budget: 58 (baseline measured 2026-03-29, includes advisory
# quality jobs). Ratchet down as allow_failure entries are removed.

set -euo pipefail

BUDGET=58

# Parse --budget flag
while [ $# -gt 0 ]; do
    case "$1" in
        --budget)
            BUDGET="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

if [ $# -lt 1 ]; then
    echo "Usage: $0 [--budget N] <path> [<path> ...]"
    echo "Example: $0 --budget 57 ."
    exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

TOTAL=0

for DIR in "$@"; do
    if [ ! -d "$DIR" ]; then
        continue
    fi

    # Find all CI YAML files
    find "$DIR" -maxdepth 3 \
        \( -name '.gitlab-ci.yml' -o -name '*.yml' -path '*/ci-templates/*' \) \
        -not -path '*/.git/*' \
        -print0 | while IFS= read -r -d '' file; do
        # Count allow_failure: true occurrences per file
        count=$(grep -c 'allow_failure:[[:space:]]*true' "$file" 2>/dev/null || true)
        if [ "$count" -gt 0 ]; then
            echo "$count $file"
        fi
    done
done > "$TMPFILE"

# Sum up
TOTAL=0
while IFS=' ' read -r count _; do
    TOTAL=$((TOTAL + count))
done < "$TMPFILE"

echo "=== allow_failure Budget Check ==="
echo "Budget: $BUDGET"
echo "Current count: $TOTAL"
echo ""

if [ -s "$TMPFILE" ]; then
    echo "Breakdown by file:"
    sort -rn "$TMPFILE" | while IFS=' ' read -r count file; do
        printf "  %3d  %s\n" "$count" "$file"
    done
    echo ""
fi

if [ "$TOTAL" -gt "$BUDGET" ]; then
    OVER=$((TOTAL - BUDGET))
    echo "FAIL: allow_failure count ($TOTAL) exceeds budget ($BUDGET) by $OVER."
    echo "Remove $OVER allow_failure: true entries before merging."
    echo "See: _private/docs/problems/2026-03-14-audit-allow-failure-ci-jobs/"
    exit 1
else
    REMAINING=$((BUDGET - TOTAL))
    echo "PASS: allow_failure count ($TOTAL) within budget ($BUDGET). $REMAINING remaining."
    exit 0
fi
