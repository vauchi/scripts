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
# assert_eq!(), assert_ne!(), assert_matches!(), prop_assert!(), #[should_panic],
# insta snapshot assertions, or .expect() calls.
#
# Suppression: Add "// allow(zero_assertions)" inside a test function body
# to suppress the warning (e.g., for intentional no-panic fuzz tests).

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
        in_body = 0
        paren_depth = 0
        brace_depth = 0
        has_assert = 0
        test_line = FNR
        test_name = ""
        next
    }
    # Phase 1: Parse function signature (before body opening brace).
    # Track paren depth to skip braces inside proptest argument patterns
    # like `name in "[A-Za-z ]{1,50}"` which would confuse the brace counter.
    # Also check for #[should_panic] which appears between #[test] and fn.
    in_test && !in_body {
        if (/fn[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*/) {
            s = $0
            gsub(/.*fn[[:space:]]+/, "", s)
            gsub(/[^a-zA-Z0-9_].*/, "", s)
            test_name = s
        }
        # Check for #[should_panic] attribute (appears before fn signature)
        if ($0 ~ /#\[should_panic/) {
            has_assert = 1
        }
        n = split($0, chars, "")
        for (i = 1; i <= n; i++) {
            if (chars[i] == "(") paren_depth++
            if (chars[i] == ")" && paren_depth > 0) paren_depth--
            if (chars[i] == "{" && paren_depth == 0) {
                in_body = 1
                brace_depth = 1
                break
            }
        }
        next
    }
    # Phase 2: Parse function body — count braces and look for assertions.
    in_test && in_body {
        n = split($0, chars, "")
        for (i = 1; i <= n; i++) {
            if (chars[i] == "{") brace_depth++
            if (chars[i] == "}") brace_depth--
        }
        # Recognized assertion patterns:
        #   assert!, assert_eq!, assert_ne!, assert_matches!  (stdlib macros)
        #   assert_foo(                                       (helper functions named assert_*)
        #   prop_assert, prop_assert_eq, prop_assert_ne       (proptest)
        #   assert_snapshot!, assert_debug_snapshot!, etc.     (insta)
        #   .expect(                                          (intentional panic-on-fail)
        #   #[should_panic]                                   (expected-panic tests)
        if ($0 ~ /assert[a-z_]*!|assert_[a-z_]+\(|prop_assert|\.expect\(|\.expect_err\(|#\[should_panic]/) {
            has_assert = 1
        }
        # Suppression: // allow(zero_assertions) inside the test body
        if ($0 ~ /\/\/.*allow\(zero_assertions\)/) {
            has_assert = 1
        }
        if (brace_depth == 0) {
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
    echo "Every #[test] function must contain at least one assertion macro (assert*!,"
    echo "prop_assert*!, insta snapshot), .expect(), or #[should_panic] annotation."
    echo "For intentional no-panic tests, add: // allow(zero_assertions)"
    exit 1
else
    echo "PASS: All test functions contain assertions."
    exit 0
fi
