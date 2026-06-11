#!/bin/bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fail when a committed snapshot baseline no longer maps to a live test
# FUNCTION. Orphaned baselines survive test deletions silently (record
# jobs only touch existing tests) and then masquerade as current UI in
# the VRT gallery and vrt.vauchi.app uploads. Found 2026-06-11: android
# shipped 17 baselines of tests deleted in the Humble-UI retirements
# (the source FILE still existed, full of tombstone comments — so the
# check is per test function, not per file); macos shipped 33 from a
# deleted test class.
#
# Usage:
#   check-orphan-baselines.sh swift   <snapshots-root> <test-src-dir>
#   check-orphan-baselines.sh compose <reference-root> <test-src-dir>
#
# swift:   <snapshots-root>/<Class>/<testName>.<n>.png needs
#          "func <testName>(" in <test-src-dir>/<Class>.swift
# compose: <reference-root>/<FileName>Kt/<TestName>_<hash>_<n>.png needs
#          "fun <TestName>(" in <FileName>.kt under <test-src-dir>

set -euo pipefail

style="${1:?style (swift|compose) required}"
baseline_root="${2:?baseline root dir required}"
test_src_dir="${3:?test source dir required}"

if [ ! -d "$baseline_root" ]; then
    echo "[orphan-baselines] No baseline dir at $baseline_root — nothing to check"
    exit 0
fi

errors=0
for dir in "$baseline_root"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")

    case "$style" in
        swift)
            src="$test_src_dir/$name.swift"
            if [ ! -f "$src" ]; then
                count=$(find "$dir" \( -name '*.png' -o -name '*.txt' \) | wc -l | tr -d ' ')
                echo "ORPHAN CLASS: $dir ($count baselines) has no $src"
                errors=$((errors + count))
                continue
            fi
            for snap in "$dir"*.png "$dir"*.txt; do
                [ -f "$snap" ] || continue
                base=$(basename "$snap")
                fn="${base%.*.png}"
                fn="${fn%.*.txt}"
                if ! grep -q "func ${fn}(" "$src"; then
                    echo "ORPHAN: $snap — no 'func ${fn}(' in $src"
                    errors=$((errors + 1))
                fi
            done
            ;;
        compose)
            src_name="${name%Kt}.kt"
            src=$(find "$test_src_dir" -name "$src_name" -type f | head -1)
            if [ -z "$src" ]; then
                count=$(find "$dir" -name '*.png' | wc -l | tr -d ' ')
                echo "ORPHAN CLASS: $dir ($count baselines) has no $src_name under $test_src_dir"
                errors=$((errors + count))
                continue
            fi
            for png in "$dir"*.png; do
                [ -f "$png" ] || continue
                base=$(basename "$png")
                fn="${base%_*_*.png}"
                if ! grep -q "fun ${fn}(" "$src"; then
                    echo "ORPHAN: $png — no 'fun ${fn}(' in $src"
                    errors=$((errors + 1))
                fi
            done
            ;;
        *)
            echo "Unknown style: $style (want swift|compose)" >&2
            exit 2
            ;;
    esac
done

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "$errors orphaned baseline(s). Delete them (git rm) — their"
    echo "tests are gone, so they show retired UI as if it were current."
    exit 1
fi
echo "[orphan-baselines] OK — every baseline maps to a live test function"
