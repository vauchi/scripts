#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The binary-size job in ci-templates/perf.yml must list each library once.
# Two overlapping globs listed every lib*.so and lib*.a twice (core job
# 16855976656 shows libvauchi_platform.so and .a twice), which put the same
# series in one payload twice; core's binary-size push was undelivered on
# every sampled main pipeline from 2026-08-20 to 2026-10-01 (private#470).

set -u

TEMPLATE="$(cd "$(dirname "$0")/../.." && pwd)/ci-templates/perf.yml"

pass=0
fail=0
check() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}

# Run the template's own loop header, not a copy of it.
globs=$(grep -m1 -E '^[[:space:]]*for lib in ' "$TEMPLATE" |
    sed -E 's/^[[:space:]]*for lib in //; s/; do[[:space:]]*$//')
check "the template still has a library loop to test" "1" "$([ -n "$globs" ] && echo 1 || echo 0)"

work=$(mktemp -d)
mkdir -p "$work/target/release"
touch "$work/target/release/libvauchi_platform.so" \
    "$work/target/release/libvauchi_platform.a" \
    "$work/target/release/standalone.a"

listed=$(cd "$work" && bash -c "for lib in $globs; do [ -f \"\$lib\" ] && basename \"\$lib\"; done")

check "libvauchi_platform.so is listed once" "1" \
    "$(printf '%s\n' "$listed" | grep -c '^libvauchi_platform\.so$')"
check "libvauchi_platform.a is listed once" "1" \
    "$(printf '%s\n' "$listed" | grep -c '^libvauchi_platform\.a$')"
check "a library without the lib prefix is still listed" "1" \
    "$(printf '%s\n' "$listed" | grep -c '^standalone\.a$')"
check "nothing is listed twice" "" "$(printf '%s\n' "$listed" | sort | uniq -d)"

rm -rf "$work"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
