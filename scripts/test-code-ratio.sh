#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# test-code-ratio.sh — Measure test-to-source line ratio for a Rust crate.
#
# Usage: test-code-ratio.sh <crate-dir>
# Output: one-line summary with crate name, src lines, test lines, ratio.

set -euo pipefail

DIR="${1:-.}"

if [ ! -d "$DIR/src" ]; then
    echo "  $DIR: no src/ directory"
    exit 0
fi

# Count non-blank, non-comment lines in src/
SRC_LINES=$(find "$DIR/src" -name '*.rs' -exec grep -cve '^\s*$' -e '^\s*//' {} + 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')

# Count non-blank, non-comment lines in tests/
if [ -d "$DIR/tests" ]; then
    TEST_LINES=$(find "$DIR/tests" -name '*.rs' -exec grep -cve '^\s*$' -e '^\s*//' {} + 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
else
    TEST_LINES=0
fi

# Inline tests (inside src/ behind #[cfg(test)])
INLINE_TEST_LINES=$(find "$DIR/src" -name '*.rs' -exec grep -c '#\[test\]' {} + 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')

if [ "$SRC_LINES" -eq 0 ]; then
    RATIO="N/A"
else
    RATIO=$(awk "BEGIN {printf \"%.1f%%\", ($TEST_LINES / $SRC_LINES) * 100}")
fi

printf "  %-30s src=%5d  test=%5d  inline_tests=%3d  ratio=%s\n" \
    "$(basename "$DIR")" "$SRC_LINES" "$TEST_LINES" "$INLINE_TEST_LINES" "$RATIO"
