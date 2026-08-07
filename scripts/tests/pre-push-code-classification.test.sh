#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# The pre-push hook skips every gate when a branch touches no "code".
# linux-qt and windows are entirely C++ and vauchi-cabi's public headers
# are C, so a classifier that does not know those extensions silently
# waved through every push in those repos. Pin the classification.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$DIR/hooks/pre-push"

PASS=0
FAIL=0

# Read the two patterns straight out of the hook so the test tracks the
# real thing rather than a copy that can drift.
CODE_PATTERN=$(sed -n "s/^[[:space:]]*CODE_PATTERN='\(.*\)'$/\1/p" "$HOOK")
BUILD_PATTERN=$(sed -n "s/^[[:space:]]*BUILD_PATTERN='\(.*\)'$/\1/p" "$HOOK")

if [ -z "$CODE_PATTERN" ] || [ -z "$BUILD_PATTERN" ]; then
    echo "FAIL: could not read CODE_PATTERN/BUILD_PATTERN from $HOOK" >&2
    exit 1
fi

# is_code <path> — mirrors the hook: code OR build counts as "not skippable".
is_code() {
    if printf '%s\n' "$1" | grep -qE "$CODE_PATTERN"; then return 0; fi
    if printf '%s\n' "$1" | grep -qE "$BUILD_PATTERN"; then return 0; fi
    return 1
}

expect_code() {
    if is_code "$1"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: '$1' should classify as code, but the hook would skip checks" >&2
    fi
}

expect_not_code() {
    if is_code "$1"; then
        FAIL=$((FAIL + 1))
        echo "FAIL: '$1' should not classify as code" >&2
    else
        PASS=$((PASS + 1))
    fi
}

# C++ shells (linux-qt, windows) and the C ABI surface.
expect_code "src/coreui/presentationcontroller.cpp"
expect_code "src/coreui/qrpasteprompt.h"
expect_code "tests/presentation_controller_test.cpp"
expect_code "src/main.cc"
expect_code "src/thing.cxx"
expect_code "include/thing.hpp"
expect_code "vauchi-cabi/include/vauchi.h"
expect_code "CMakeLists.txt"
expect_code "tests/render_fixture_smoke.cmake"

# Previously covered languages must keep classifying as code.
expect_code "src/lib.rs"
expect_code "Sources/App/View.swift"
expect_code "app/src/main/java/App.kt"
expect_code "Cargo.toml"

# Genuinely non-code stays on the fast path.
expect_not_code "README.md"
expect_not_code "docs/guide.md"
expect_not_code ".gitignore"
expect_not_code "assets/logo.png"

echo "pre-push code classification: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
