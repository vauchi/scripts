#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Regression suite for vrt-upload.sh.
#
# Network paths (the actual VRT API calls) are not exercised — they
# need live credentials. Instead, we test two structural properties
# that govern correctness when VRT_SCREENSHOT_DIR contains optional
# theme subdirs (e.g. baseline/{dark,light}/ for the dark-mode
# snapshot parity gate, record `2026-05-01-dark-mode-snapshot-parity`):
#
#   1. `vrt_test_name` derivation: a flat layout maps to a single-
#      token name (backwards-compatible), a depth-2 layout prefixes
#      the subdir so dark/light siblings don't collapse on VRT.
#   2. `find -maxdepth 2 -type f -name "*.png"` walks both depth-1
#      and depth-2 PNG files from a fixture directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../ci/vrt-upload.sh"

pass=0
fail=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        printf '  PASS %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s — want %q, got %q\n' "$name" "$want" "$got" >&2
        fail=$((fail + 1))
    fi
}

# Pull the helper definition out of the script via awk. Sourcing
# the script directly would short-circuit on the `VRT_API_KEY not set`
# skip; the helper is a pure function so extraction is harmless.
extract_helper() {
    awk '
        /^vrt_test_name\(\)/ { capturing = 1 }
        capturing { print }
        capturing && /^}$/   { capturing = 0 }
    ' "$SCRIPT"
}

run_helper_tests() {
    eval "$(extract_helper)"

    # Flat layout — must match pre-2026-05-23 behaviour.
    assert_eq "flat: single token"        "contacts"           "$(vrt_test_name '/r/contacts.png' '/r')"
    assert_eq "flat: snake_case → spaces" "my card"            "$(vrt_test_name '/r/my_card.png' '/r')"
    assert_eq "flat: kebab → spaces"      "primary button"     "$(vrt_test_name '/r/primary-button.png' '/r')"

    # Depth-2 layout — theme subdir becomes a leading token.
    assert_eq "depth-2: dark prefix"      "dark my card"       "$(vrt_test_name '/r/dark/my_card.png' '/r')"
    assert_eq "depth-2: light prefix"     "light my card"      "$(vrt_test_name '/r/light/my_card.png' '/r')"

    # Mixed delimiters and consecutive separators get squashed to one space.
    assert_eq "squash: double underscore" "a b c"              "$(vrt_test_name '/r/a__b_c.png' '/r')"
    assert_eq "squash: subdir + mixed"    "dark test setup view" "$(vrt_test_name '/r/dark/test_setup-view.png' '/r')"

    # The same screen captured under both themes must yield distinct
    # names — this is the property the depth-2 walk has to preserve,
    # since VRT compares uploads by the `name` field.
    local dark light
    dark="$(vrt_test_name '/r/dark/my_card.png' '/r')"
    light="$(vrt_test_name '/r/light/my_card.png' '/r')"
    if [[ "$dark" != "$light" ]]; then
        printf '  PASS dark/light names diverge\n'
        pass=$((pass + 1))
    else
        printf '  FAIL dark/light names diverge — both = %q\n' "$dark" >&2
        fail=$((fail + 1))
    fi
}

run_find_tests() {
    local tmp
    tmp="$(mktemp -d 2>/dev/null || mktemp -d -t vrt-upload-test)"
    trap 'rm -rf "$tmp"' EXIT

    # Flat-layout fixture (pre-2026-05-23 consumer shape).
    mkdir -p "$tmp/flat"
    : > "$tmp/flat/a.png"
    : > "$tmp/flat/b.png"

    # Depth-2 fixture (new linux-qt shape).
    mkdir -p "$tmp/themed/dark" "$tmp/themed/light"
    : > "$tmp/themed/dark/my_card.png"
    : > "$tmp/themed/dark/contacts.png"
    : > "$tmp/themed/light/my_card.png"
    : > "$tmp/themed/light/contacts.png"

    # Mixed fixture (no consumer uses this today but `find` must
    # behave correctly if anyone ever lands on it).
    mkdir -p "$tmp/mixed/dark"
    : > "$tmp/mixed/top.png"
    : > "$tmp/mixed/dark/leaf.png"

    # Non-png siblings the walker must NOT pick up.
    : > "$tmp/flat/readme.txt"
    : > "$tmp/themed/dark/diff.json"

    local flat_count themed_count mixed_count
    flat_count=$(find "$tmp/flat" -maxdepth 2 -type f -name "*.png" | wc -l | tr -d ' ')
    themed_count=$(find "$tmp/themed" -maxdepth 2 -type f -name "*.png" | wc -l | tr -d ' ')
    mixed_count=$(find "$tmp/mixed" -maxdepth 2 -type f -name "*.png" | wc -l | tr -d ' ')

    assert_eq "find: flat layout finds 2 PNG files"    "2" "$flat_count"
    assert_eq "find: themed layout finds 4 PNG files"  "4" "$themed_count"
    assert_eq "find: mixed layout finds 2 PNG files"   "2" "$mixed_count"

    rm -rf "$tmp"
    trap - EXIT
}

printf 'vrt-upload helper tests:\n'
run_helper_tests
printf 'vrt-upload find-walk tests:\n'
run_find_tests

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
