#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# test-code-ratio.sh — Measure test-to-code ratio (TLOC / ELOC) for a project
#
# Usage: test-code-ratio.sh <project_directory>
# Example: test-code-ratio.sh core/vauchi-core/
#
# Counts lines of Rust source in src/ (production code) vs tests/ (test code)
# and reports the ratio. Also counts inline #[cfg(test)] modules in src/.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <project_directory>"
    echo "Example: $0 core/vauchi-core/"
    exit 1
fi

DIR="$1"

if [ ! -d "$DIR" ]; then
    echo "Error: $DIR is not a directory"
    exit 1
fi

SRC_DIR="$DIR/src"
TEST_DIR="$DIR/tests"

count_lines() {
    local dir="$1"
    local ext="$2"
    if [ -d "$dir" ]; then
        find "$dir" -name "*.$ext" -exec cat {} + 2>/dev/null | wc -l
    else
        echo 0
    fi
}

# Count production code lines (src/)
SRC_LINES=0
if [ -d "$SRC_DIR" ]; then
    SRC_LINES=$(count_lines "$SRC_DIR" "rs")
fi

# Count test code lines (tests/)
TEST_LINES=0
if [ -d "$TEST_DIR" ]; then
    TEST_LINES=$(count_lines "$TEST_DIR" "rs")
fi

# Count inline test module lines in src/ (#[cfg(test)] mod tests { ... })
INLINE_TEST_LINES=0
if [ -d "$SRC_DIR" ]; then
    INLINE_TEST_LINES=$(find "$SRC_DIR" -name "*.rs" -exec awk '
        /#\[cfg\(test\)\]/ { in_test = 1; depth = 0 }
        in_test {
            count++
            n = split($0, c, "")
            for (i = 1; i <= n; i++) {
                if (c[i] == "{") depth++
                if (c[i] == "}") depth--
            }
            if (depth == 0 && count > 1) { in_test = 0; count = 0 }
        }
        END { print count + 0 }
    ' {} + 2>/dev/null || echo 0)
fi

# Total test lines = external tests + inline test modules
TOTAL_TEST_LINES=$((TEST_LINES + INLINE_TEST_LINES))

# Production lines = src lines minus inline test lines
PROD_LINES=$((SRC_LINES - INLINE_TEST_LINES))

# Calculate ratio
if [ "$PROD_LINES" -gt 0 ]; then
    RATIO=$(awk "BEGIN { printf \"%.1f\", ($TOTAL_TEST_LINES / $PROD_LINES) * 100 }")
else
    RATIO="N/A"
fi

echo "=== Test-to-Code Ratio ==="
echo "Project: $DIR"
echo ""
echo "Production code (src/ minus inline tests): $PROD_LINES lines"
echo "Test code (tests/):                        $TEST_LINES lines"
echo "Inline test modules (src/ #[cfg(test)]):   $INLINE_TEST_LINES lines"
echo "Total test code:                           $TOTAL_TEST_LINES lines"
echo ""
echo "Test-to-code ratio: ${RATIO}%"
echo ""

if [ "$RATIO" != "N/A" ]; then
    RATIO_NUM=$(echo "$RATIO" | tr -d '%')
    if awk "BEGIN { exit !($RATIO_NUM >= 50) }"; then
        echo "PASS: Ratio meets 50% target"
    else
        echo "NOTE: Ratio below 50% target (industry standard for mature projects)"
    fi
fi
