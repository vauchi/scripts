#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-stale-ci-pin.sh — VSP01: a pinned
# ci-templates ref must be among the most recent published tags.
# Rule page: _private/docs/lint-errors/vsp01-stale-ci-template-pin.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-stale-ci-pin.sh"

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
has() { printf '%s' "$2" | grep -q "$1" && echo 1 || echo 0; }

RECENT="$(mktemp)"
printf 'ci-templates-v2026.07.8\nci-templates-v2026.07.7\nci-templates-v2026.07.6\n' > "$RECENT"

run() { out="$("$SCRIPT" "$1" "$RECENT" test-repo 2>&1)"; rc=$?; }

# ── current pin (among recent tags): exit 0 ───────────────────────────
Y="$(mktemp)"
printf '  ref: ci-templates-v2026.07.8\n  VAR: "ci-templates-v2026.07.8"\n' > "$Y"
run "$Y"
assert_eq "current pin: exit 0" "0" "$rc"
rm -f "$Y"

# ── stale pin (not among recent tags): exit 1 ─────────────────────────
Y="$(mktemp)"
printf '  ref: ci-templates-v2026.07.2\n' > "$Y"
run "$Y"
assert_eq "stale pin: exit 1" "1" "$rc"
assert_eq "stale pin: VSP01" "1" "$(has VSP01 "$out")"
assert_eq "stale pin: names the pin" "1" "$(has 'ci-templates-v2026.07.2' "$out")"
rm -f "$Y"

# ── no ci-template pin present: exit 0 ────────────────────────────────
Y="$(mktemp)"
printf 'stages:\n  - lint\n' > "$Y"
run "$Y"
assert_eq "no pins: exit 0" "0" "$rc"
rm -f "$Y"

rm -f "$RECENT"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
