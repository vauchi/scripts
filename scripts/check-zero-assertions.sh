#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-zero-assertions.sh — Scan Rust test files for #[test] functions with zero assertions
#
# Usage: check-zero-assertions.sh <test_directory>
# Example: check-zero-assertions.sh core/vauchi-core/tests/
#
# Exits non-zero if any zero-assertion test functions are found.
# A "zero-assertion test" is a #[test] function that contains no assert!(),
# assert_eq!(), assert_ne!(), assert_matches!(), prop_assert!(), or #[should_panic].

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <test_directory> [<test_directory> ...]"
    echo "Example: $0 core/vauchi-core/tests/"
    exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

for DIR in "$@"; do
    if [ ! -d "$DIR" ]; then
        echo "Warning: $DIR is not a directory, skipping" >&2
        continue
    fi

    # shellcheck disable=SC2016
    find "$DIR" -name '*.rs' -print0 | xargs -0 awk '
    FNR == 1 { file_line_offset = NR - 1 }
    /^[[:space:]]*#\[test\]/ {
        in_test = 1
        brace_depth = 0
        has_assert = 0
        test_line = FNR
        test_name = ""
        next
    }
    in_test && /fn[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*/ {
        s = $0
        gsub(/.*fn[[:space:]]+/, "", s)
        gsub(/[^a-zA-Z0-9_].*/, "", s)
        test_name = s
    }
    in_test {
        n = split($0, chars, "")
        for (i = 1; i <= n; i++) {
            if (chars[i] == "{") brace_depth++
            if (chars[i] == "}") brace_depth--
        }
        if ($0 ~ /assert!|assert_eq!|assert_ne!|assert_matches!|prop_assert|#\[should_panic/) {
            has_assert = 1
        }
        if (brace_depth == 0 && FNR != test_line) {
            if (!has_assert) {
                printf "ZERO %s:%d %s\n", FILENAME, test_line, test_name
            }
            printf "TOTAL\n"
            in_test = 0
        }
    }
    '
done > "$TMPFILE"

TOTAL_TESTS=$(grep -c "^TOTAL" "$TMPFILE" || true)
ZERO_ASSERTION_TESTS=$(grep -c "^ZERO" "$TMPFILE" || true)

echo "=== Zero-Assertion Test Scanner ==="
echo "Directories scanned: $*"
echo "Total #[test] functions found: $TOTAL_TESTS"
echo "Zero-assertion tests found: $ZERO_ASSERTION_TESTS"
echo ""

if [ "$ZERO_ASSERTION_TESTS" -gt 0 ]; then
    echo "Tests with zero assertions:"
    grep "^ZERO" "$TMPFILE" | while IFS=' ' read -r _ location name; do
        echo "  $location — $name()"
    done
    echo ""
    echo "FAIL: Found test functions with zero assertions."
    echo "Every #[test] function must contain at least one assert!(), assert_eq!(),"
    echo "assert_ne!(), assert_matches!(), prop_assert!(), or #[should_panic] annotation."
    exit 1
else
    echo "PASS: All test functions contain assertions."
    exit 0
fi
