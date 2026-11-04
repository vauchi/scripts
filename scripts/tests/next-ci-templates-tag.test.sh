#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for ci/next-ci-templates-tag.sh: the next templates tag is
# today's date, or one past the month's highest tag when today's is taken or
# behind it, so the tags keep sorting in release order (private#1068).

set -u

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/scripts/ci/next-ci-templates-tag.sh"

pass=0
fail=0
assert_eq() {
    name="$1"; want="$2"; got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1)); printf '  PASS %s\n' "$name"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got" >&2
    fi
}
next() { printf '%s' "$1" | "$SCRIPT" "$2" 2>/dev/null; }

TAGS='ci-templates-v2026.10.31
ci-templates-v2026.11.02
ci-templates-v2026.11.03
ci-templates-v2026.11.05
v0.98.0'

assert_eq "a free date later than the month's tags is today's" \
    "ci-templates-v2026.11.09" "$(next "$TAGS" 2026-11-09)"
assert_eq "today's tag taken: one past the month's highest" \
    "ci-templates-v2026.11.06" "$(next "$TAGS" 2026-11-05)"
assert_eq "today behind the month's highest: one past it" \
    "ci-templates-v2026.11.06" "$(next "$TAGS" 2026-11-04)"
assert_eq "a new month starts from its date" \
    "ci-templates-v2026.12.01" "$(next "$TAGS" 2026-12-01)"
assert_eq "no tags at all: today's date, zero-padded" \
    "ci-templates-v2026.11.07" "$(next "" 2026-11-07)"
assert_eq "a malformed date is refused" "" "$(next "$TAGS" 2026-11)"

printf '%s' "$TAGS" | "$SCRIPT" 2026-11 >/dev/null 2>&1
assert_eq "a malformed date exits non-zero" "1" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
