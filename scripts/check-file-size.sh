#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# check-file-size.sh — Scan Rust source files for excessive line counts
#
# Usage: check-file-size.sh [OPTIONS] <directory> [<directory> ...]
# Example: check-file-size.sh core/
#          check-file-size.sh --advisory core/ cli/ relay/
#          check-file-size.sh --generate-baseline core/
#
# Thresholds:
#   Source files (*.rs):         warn >500, error >1000
#   Test files (tests/**/*.rs):  warn >800, error >1200
#
# Reads .file-size-baseline in <directory> root for grandfathered files.
# Grandfathered files only fail if they GROW beyond their baseline.
#
# Suppression: Add "// allow(large_file)" on line 1 of a file.
#
# Flags:
#   --advisory           Exit 0 always (print warnings only)
#   --generate-baseline  Output baseline entries for files exceeding error threshold

set -euo pipefail

# ── Thresholds ────────────────────────────────────────────────────────
SRC_WARN=500
SRC_ERROR=1000
TEST_WARN=800
TEST_ERROR=1200

# ── Parse flags ───────────────────────────────────────────────────────
ADVISORY=false
GENERATE_BASELINE=false
DIRS=()

for arg in "$@"; do
    case "$arg" in
        --advisory)          ADVISORY=true ;;
        --generate-baseline) GENERATE_BASELINE=true ;;
        -*)                  echo "Unknown flag: $arg" >&2; exit 1 ;;
        *)                   DIRS+=("$arg") ;;
    esac
done

if [ ${#DIRS[@]} -lt 1 ]; then
    echo "Usage: $0 [--advisory] [--generate-baseline] <directory> [<directory> ...]"
    echo "Example: $0 core/"
    exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

# ── Classify file as test or source ───────────────────────────────────
# Test if path contains /tests/ directory or ends with _test.rs/_tests.rs
is_test_file() {
    local filepath="$1"
    case "$filepath" in
        */tests/*|*_test.rs|*_tests.rs) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Read baseline ─────────────────────────────────────────────────────
# Returns baseline line count for a file, or empty string if not baselined.
# Baseline format: <relative_path> <line_count>
# Lines starting with # are comments.
get_baseline() {
    local filepath="$1"
    local baseline_file="$2"
    if [ ! -f "$baseline_file" ]; then
        echo ""
        return
    fi
    # Match file path (first column) and return line count (second column)
    while IFS=' ' read -r path count; do
        # Skip comments and empty lines
        case "$path" in
            '#'*|'') continue ;;
        esac
        if [ "$path" = "$filepath" ]; then
            echo "$count"
            return
        fi
    done < "$baseline_file"
    echo ""
}

# ── Check suppression ────────────────────────────────────────────────
has_suppression() {
    local filepath="$1"
    # Check line 1 for // allow(large_file)
    head -1 "$filepath" 2>/dev/null | grep -q '//.*allow(large_file)' && return 0
    return 1
}

# ── Main scan ─────────────────────────────────────────────────────────
WARN_COUNT=0
FAIL_COUNT=0
BASELINE_ENTRIES=()

for DIR in "${DIRS[@]}"; do
    if [ ! -d "$DIR" ]; then
        echo "Warning: $DIR is not a directory, skipping" >&2
        continue
    fi

    # Resolve baseline file at the root of the scanned directory
    BASELINE_FILE="$DIR/.file-size-baseline"

    # Find all .rs files (excluding target/ and build artifacts)
    while IFS= read -r -d '' filepath; do
        # Skip build artifacts, cargo caches, and vendored dependencies
        case "$filepath" in
            */target/*|*/build/*|*/.cargo/*|*/vendor/*|vendor/*) continue ;;
        esac
        # Count lines
        lines=$(wc -l < "$filepath" | tr -d ' ')

        # Determine thresholds
        if is_test_file "$filepath"; then
            warn_threshold=$TEST_WARN
            error_threshold=$TEST_ERROR
            kind="test"
        else
            warn_threshold=$SRC_WARN
            error_threshold=$SRC_ERROR
            kind="src"
        fi

        # Strip DIR prefix to get relative path
        # Normalize: remove trailing slash from DIR before stripping
        local_dir="${DIR%/}"
        relpath="${filepath#"$local_dir"/}"

        # Generate baseline mode: just output files above error threshold
        if [ "$GENERATE_BASELINE" = true ]; then
            if [ "$lines" -gt "$error_threshold" ]; then
                BASELINE_ENTRIES+=("$relpath $lines")
            fi
            continue
        fi

        # Check suppression
        if has_suppression "$filepath"; then
            continue
        fi
        baseline=$(get_baseline "$relpath" "$BASELINE_FILE")

        if [ -n "$baseline" ]; then
            # Grandfathered file: only fail if it GREW beyond baseline
            if [ "$lines" -gt "$baseline" ]; then
                echo "FAIL $filepath ($lines lines, baseline $baseline — grew by $((lines - baseline)))" >> "$TMPFILE"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
            # Skip normal threshold checks for baselined files
            continue
        fi

        # Normal threshold checks (non-baselined files)
        if [ "$lines" -gt "$error_threshold" ]; then
            echo "FAIL $filepath ($lines lines, $kind error threshold $error_threshold)" >> "$TMPFILE"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [ "$lines" -gt "$warn_threshold" ]; then
            echo "WARN $filepath ($lines lines, $kind warn threshold $warn_threshold)" >> "$TMPFILE"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    done < <(find "$DIR" -name '*.rs' -type f \
        -not -path '*/target/*' \
        -not -path '*/.cargo/*' \
        -not -path '*/vendor/*' \
        -not -path '*/build/*' \
        -print0 | sort -z)
done

# ── Generate baseline output ─────────────────────────────────────────
if [ "$GENERATE_BASELINE" = true ]; then
    echo "# Generated $(date +%Y-%m-%d). Files above error threshold, grandfathered."
    echo "# These files must not grow beyond their baseline. Reduce over time."
    for entry in "${BASELINE_ENTRIES[@]}"; do
        echo "$entry"
    done
    exit 0
fi

# ── Report ────────────────────────────────────────────────────────────
echo "=== File Size Scanner ==="
echo "Directories scanned: ${DIRS[*]}"
echo "Warnings: $WARN_COUNT"
echo "Failures: $FAIL_COUNT"
echo ""

if [ -s "$TMPFILE" ]; then
    # Show warnings first, then failures
    grep "^WARN" "$TMPFILE" | while IFS= read -r line; do
        echo "  ${line}"
    done || true
    grep "^FAIL" "$TMPFILE" | while IFS= read -r line; do
        echo "  ${line}"
    done || true
    echo ""
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "FAIL: $FAIL_COUNT file(s) exceed error threshold."
    echo "Options:"
    echo "  - Split the file into smaller modules"
    echo "  - Add to .file-size-baseline if structurally necessary"
    echo "  - Add '// allow(large_file)' on line 1 for exemptions (migrations, FFI)"
    if [ "$ADVISORY" = true ]; then
        echo ""
        echo "(advisory mode — exiting 0)"
        exit 0
    fi
    exit 1
else
    if [ "$WARN_COUNT" -gt 0 ]; then
        echo "PASS (with $WARN_COUNT warning(s)). Consider splitting large files."
    else
        echo "PASS: All files within size limits."
    fi
    exit 0
fi
