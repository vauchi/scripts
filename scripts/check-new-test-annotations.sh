#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-new-test-annotations.sh — Hard gate for scenario annotations on new tests
#
# Parses the git diff between two commits to find newly added #[test] and
# #[tokio::test] functions.  For each, checks the actual file content for
# a @scenario: or @internal annotation within the 5 preceding lines.
#
# Exits 1 if any new test lacks an annotation — designed as a CI gate.
#
# Usage: check-new-test-annotations.sh <base_sha> [<head_sha>]
#   base_sha: merge-request diff base (CI_MERGE_REQUEST_DIFF_BASE_SHA)
#   head_sha: defaults to HEAD
#
# Convention (same as check-scenario-annotations.sh):
#   // @scenario: feature_name :: scenario description
#   // @internal — test doesn't map to a Gherkin scenario

set -euo pipefail

BASE="${1:-}"
HEAD="${2:-HEAD}"

if [ -z "$BASE" ]; then
    echo "Usage: $0 <base_sha> [<head_sha>]"
    exit 1
fi

FOUND=0
MISSING=0
REPORT=""

# Process each changed Rust file
while IFS= read -r file; do
    [ -z "$file" ] && continue
    [ ! -f "$file" ] && continue

    # Extract file-relative line numbers of added #[test] / #[tokio::test]
    # markers from the unified diff.  Hunk headers (@@ -o,n +new,n @@) give
    # the starting line number; we count added (+) and context ( ) lines to
    # track position.
    added_test_lines=$(
        git diff "$BASE"..."$HEAD" -- "$file" 2>/dev/null |
        awk '
            /^@@ / {
                s = $3
                gsub(/\+/, "", s)
                split(s, a, ",")
                new_line = a[1] - 1
                next
            }
            /^\+/ && !/^\+\+\+/ {
                new_line++
                line = substr($0, 2)
                if (line ~ /^[[:space:]]*#\[test\]/ ||
                    line ~ /^[[:space:]]*#\[tokio::test\]/) {
                    print new_line
                }
                next
            }
            /^ / { new_line++; next }
        '
    )

    for tl in $added_test_lines; do
        FOUND=$((FOUND + 1))

        # Check 5 lines above in the actual file for annotation
        start=$((tl > 5 ? tl - 5 : 1))
        end=$((tl - 1))
        has_ann=0
        if [ "$end" -ge "$start" ]; then
            while IFS= read -r ctx; do
                case "$ctx" in
                    *@scenario:*) has_ann=1 ;;
                    *@internal*)  has_ann=1 ;;
                esac
            done < <(sed -n "${start},${end}p" "$file")
        fi

        if [ "$has_ann" -eq 0 ]; then
            # Extract the function name from lines following #[test]
            fn_name=$(sed -n "$((tl + 1)),$((tl + 5))p" "$file" |
                grep -m1 'fn[[:space:]]' |
                sed 's/.*fn[[:space:]]*\([a-zA-Z_][a-zA-Z0-9_]*\).*/\1/' || true)
            MISSING=$((MISSING + 1))
            REPORT="${REPORT}  ${file}:${tl} — ${fn_name:-unknown}()\n"
        fi
    done
done < <(git diff --name-only "$BASE"..."$HEAD" -- '*.rs' 2>/dev/null)

echo "=== New Test Annotation Gate ==="
echo "New #[test] functions in this MR: $FOUND"

if [ "$FOUND" -eq 0 ]; then
    echo "No new tests — nothing to check"
    exit 0
fi

if [ "$MISSING" -gt 0 ]; then
    echo "FAILED: $MISSING new test(s) missing annotations:"
    echo ""
    printf "%b" "$REPORT"
    echo ""
    echo "Fix: add one of these above #[test]:"
    echo "  // @scenario: feature_name :: scenario description"
    echo "  // @internal"
    exit 1
fi

echo "All $FOUND new test(s) have annotations"
exit 0
