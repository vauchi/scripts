#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sentinel suite for scripts/check-seeded-violation-tests.sh — CC-27
# enforcement tier: every check-*.sh has a paired *.test.sh, ratcheted
# from a baseline of grandfathered scripts that may only shrink.
# Rule page: _private/docs/lint-errors/cc27-prove-it-can-fail.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/check-seeded-violation-tests.sh"

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

# Builds a throwaway scripts-repo layout: hooks/, scripts/, scripts/tests/
# and a baseline file. $1 = baseline content; remaining args = files to
# create (paths relative to the repo root).
run_case() {
    baseline="$1"; shift
    root="$(mktemp -d)"
    mkdir -p "$root/hooks" "$root/scripts/tests" "$root/scripts/ci"
    printf '%s\n' "$baseline" > "$root/scripts/.seeded-violation-baseline"
    for p in "$@"; do
        mkdir -p "$root/$(dirname "$p")"
        printf '#!/bin/sh\nexit 0\n' > "$root/$p"
    done
    out="$("$SCRIPT" "$root" 2>&1)"; rc=$?
    rm -rf "$root"
}

# ── every check paired → pass ─────────────────────────────────────────
run_case '' scripts/check-a.sh scripts/tests/check-a.test.sh
assert_eq "paired check: exit 0" "0" "$rc"

# ── a variant-named test still counts as the pair ─────────────────────
run_case '' scripts/check-portable-shell.sh scripts/tests/check-portable-shell-vsh13.test.sh
assert_eq "prefix-named test pairs: exit 0" "0" "$rc"

# ── new unpaired check not in baseline → fail, names the fix ──────────
run_case '' scripts/check-new.sh
assert_eq "unpaired new check: exit 1" "1" "$rc"
assert_eq "unpaired new check: CC-27 in message" "1" \
    "$(printf '%s' "$out" | grep -q 'CC-27:' && echo 1 || echo 0)"
assert_eq "unpaired new check: names the fix" "1" \
    "$(printf '%s' "$out" | grep -qE 'CC-27: .+ — fix: .+' && echo 1 || echo 0)"
assert_eq "unpaired new check: names the script" "1" \
    "$(printf '%s' "$out" | grep -q 'scripts/check-new.sh' && echo 1 || echo 0)"

# ── unpaired check listed in baseline → grandfathered, warn only ──────
run_case 'scripts/check-old.sh' scripts/check-old.sh
assert_eq "baselined check: exit 0" "0" "$rc"
assert_eq "baselined check: warns" "1" \
    "$(printf '%s' "$out" | grep -qi 'grandfathered' && echo 1 || echo 0)"

# ── baseline entry that gained a test → ratchet down, fail until pruned
run_case 'scripts/check-old.sh' scripts/check-old.sh scripts/tests/check-old.test.sh
assert_eq "stale baseline entry: exit 1" "1" "$rc"
assert_eq "stale baseline entry: asks to remove it" "1" \
    "$(printf '%s' "$out" | grep -qi 'remove' && echo 1 || echo 0)"

# ── baseline entry whose script no longer exists → fail (dead entry) ──
run_case 'scripts/check-gone.sh' scripts/check-a.sh scripts/tests/check-a.test.sh
assert_eq "dead baseline entry: exit 1" "1" "$rc"

# ── hooks/ and scripts/ci/ are in scope ───────────────────────────────
run_case '' hooks/check-h.sh
assert_eq "hooks/ check unpaired: exit 1" "1" "$rc"
run_case '' scripts/ci/check-c.sh
assert_eq "scripts/ci/ check unpaired: exit 1" "1" "$rc"

# ── test files themselves are never treated as checks ─────────────────
run_case '' scripts/tests/check-x.test.sh
assert_eq "test file alone: exit 0" "0" "$rc"

# ── the real repo passes against its own baseline ─────────────────────
out="$("$SCRIPT" "$(cd "$SCRIPT_DIR/.." && pwd)" 2>&1)"; rc=$?
assert_eq "live repo against live baseline: exit 0" "0" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
