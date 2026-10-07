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
# Default budget: 71 — the whole workspace (with _private). Measured 63 on
# 2026-09-28 after the ios/macos/android design-token checks became
# blocking (#407); raised to 71 on 2026-10-07 by owner decision for
# deliberate advisory jobs, chiefly #476's check:pictogram-copies-current
# (vauchi/private#543). 2026-09-27 set the rules: allow_failure on manual
# jobs and manual rules does not count, ci/ includes do (#72). The nightly
# root CI job cannot clone _private and enforces the public share, 67,
# via --budget.
# Ratchet both down as allow_failure entries are removed; never raise one
# to make a check pass.

set -euo pipefail

BUDGET=71

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
    # ci/*.yml: local includes (core keeps most of its jobs there).
    find "$DIR" -maxdepth 3 \
        \( -name '.gitlab-ci.yml' -o -name '*.yml' -path '*/ci-templates/*' \
           -o -name '*.yml' -path '*/ci/*' \) \
        -not -path '*/.git/*' | while IFS= read -r file; do
        # Per job block: a `when: manual` job needs allow_failure: true to
        # not block the pipeline, so it is an opt-in gate, not a silently
        # failing check. That holds per rule entry too: allow_failure on a
        # manual rule does not count, while job-level allow_failure still
        # does whenever any rule runs the job automatically.
        count=$(awk '
            function indent_of(line) { match(line, /^ */); return RLENGTH }
            function flush_rule() {
                if (!rule_manual) n += rule_af
                rule_af = 0; rule_manual = 0; in_rule = 0
            }
            function flush() {
                flush_rule(); if (!manual) total += n
                n = 0; manual = 0; in_rules = 0; rule_indent = -1
            }
            /^[^ \t#][^:]*:/ { flush() }
            /^  [A-Za-z_]+:/ {
                flush_rule(); in_rules = ($0 ~ /^  rules:/); rule_indent = -1
            }
            in_rules && /^ *- / {
                if (rule_indent < 0) rule_indent = indent_of($0)
                if (indent_of($0) == rule_indent) { flush_rule(); in_rule = 1 }
            }
            in_rule && /when:[ \t]*manual/ { rule_manual = 1 }
            /^[ \t]*(- )?allow_failure:[ \t]*true/ {
                if (in_rule) rule_af++; else n++
            }
            /^  when:[ \t]*manual/ { manual = 1 }
            END { flush(); print total + 0 }
        ' "$file")
        if [ "$count" -gt 0 ]; then
            echo "$count $file"
        fi
    done
done > "$TMPFILE"

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
    echo "See: _private/docs/problems/done/2026-09-13-allow-failure-budget-doubled-unenforced/"
    exit 1
else
    REMAINING=$((BUDGET - TOTAL))
    echo "PASS: allow_failure count ($TOTAL) within budget ($BUDGET). $REMAINING remaining."
    exit 0
fi
