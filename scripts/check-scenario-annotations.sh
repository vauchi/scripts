#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-scenario-annotations.sh — Warn about #[test] functions missing
# @scenario: or @internal annotations.
#
# Usage: check-scenario-annotations.sh <test_directory> [<test_directory> ...]
# Example: check-scenario-annotations.sh tests/ src/
#
# Exits 0 always (warning only). Prints unannotated test count and list.
#
# Convention:
#   // @scenario: feature_name :: scenario description
#   // @internal — test doesn't map to a Gherkin scenario
#
# Either annotation must appear within 5 lines above #[test].

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <test_directory> [<test_directory> ...]"
    echo "Example: $0 tests/ src/"
    exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

for DIR in "$@"; do
    if [ ! -d "$DIR" ]; then
        continue
    fi

    # shellcheck disable=SC2016
    find "$DIR" -name '*.rs' -not -path '*/vendor/*' -print0 | xargs -0 awk '
    BEGIN {
        # Ring buffer for last 5 lines
        for (i = 0; i < 5; i++) buf[i] = ""
        buf_idx = 0
    }
    FNR == 1 {
        # Reset on new file
        for (i = 0; i < 5; i++) buf[i] = ""
        buf_idx = 0
    }
    {
        # Store current line in ring buffer
        buf[buf_idx % 5] = $0
        buf_idx++
    }
    /^[[:space:]]*#\[test\]/ {
        # Check ring buffer for annotation in preceding lines
        has_annotation = 0
        for (i = 1; i <= 5; i++) {
            prev = buf[(buf_idx - 1 - i + 500) % 5]
            if (prev ~ /\/\/[[:space:]]*@scenario:/) has_annotation = 1
            if (prev ~ /\/\/[[:space:]]*@internal/) has_annotation = 1
        }
        # Capture function name from next non-attribute line
        test_line = FNR
        annotated = has_annotation
        in_test_attr = 1
        next
    }
    in_test_attr {
        if (/fn[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*/) {
            s = $0
            gsub(/.*fn[[:space:]]+/, "", s)
            gsub(/[^a-zA-Z0-9_].*/, "", s)
            if (!annotated) {
                printf "MISSING %s:%d %s\n", FILENAME, test_line, s
            }
            printf "TOTAL\n"
            in_test_attr = 0
        }
        # Skip intermediate attributes like #[should_panic], #[cfg(...)], etc.
        if (!/^[[:space:]]*#\[/ && !/^[[:space:]]*\/\//) {
            if (!/fn[[:space:]]/) {
                in_test_attr = 0
            }
        }
    }
    '
done > "$TMPFILE"

TOTAL_TESTS=$(grep -c "^TOTAL" "$TMPFILE" || true)
MISSING=$(grep -c "^MISSING" "$TMPFILE" || true)
ANNOTATED=$((TOTAL_TESTS - MISSING))

if [ "$TOTAL_TESTS" -eq 0 ]; then
    echo "=== Scenario Annotation Check ==="
    echo "No #[test] functions found in: $*"
    exit 0
fi

PCT=0
if [ "$TOTAL_TESTS" -gt 0 ]; then
    PCT=$((ANNOTATED * 100 / TOTAL_TESTS))
fi

echo "=== Scenario Annotation Check ==="
echo "Directories scanned: $*"
echo "Total #[test] functions: $TOTAL_TESTS"
echo "Annotated (@scenario: or @internal): $ANNOTATED ($PCT%)"
echo "Missing annotation: $MISSING"
echo ""

if [ "$MISSING" -gt 0 ]; then
    echo "Tests missing @scenario: or @internal annotation:"
    # Extract first 30 missing entries to a temp var to avoid SIGPIPE
    # under pipefail (head closing a pipe mid-stream exits 141).
    SAMPLE=$(grep "^MISSING" "$TMPFILE" | head -30 || true)
    while IFS=' ' read -r _ location name; do
        echo "  $location — $name()"
    done <<< "$SAMPLE"
    if [ "$MISSING" -gt 30 ]; then
        echo "  ... and $((MISSING - 30)) more"
    fi
    echo ""
    echo "WARN: $MISSING test(s) lack traceability annotations."
    echo "Add '// @scenario: feature :: description' or '// @internal' above #[test]."
fi

# Always exit 0 — this is a warning gate, not a blocker
exit 0
