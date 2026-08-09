#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# The checker exists because a shell that renders an overlay and ignores
# the dismissal says nothing at all — so a green run from it must mean
# something. Per CC-27 this asserts both directions, and the direction
# that matters is the failing one.
#
# Exemptions live in each shell's own repo
# (`.shell-command-conformance-allowlist`), so these cases write that file
# into a synthetic checkout rather than staging a central one.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/check-shell-command-conformance.py"
ALLOWLIST=".shell-command-conformance-allowlist"

[ -f "$SCRIPT" ] || { echo "FAIL: checker not found at $SCRIPT" >&2; exit 1; }

pass=0
fail=0

# make_shell <root> <shell> <src-contents> [allowlist-contents]
make_shell() {
    mkdir -p "$1/$2/src"
    printf '%s\n' "$3" > "$1/$2/src/state.ts"
    [ $# -ge 4 ] && printf '%s\n' "$4" > "$1/$2/$ALLOWLIST"
    return 0
}

# expect <label> <want-exit> <mode:workspace|shell> <src> [allowlist]
expect() {
    label=$1; want=$2; mode=$3; src=$4; allow=${5-}
    root=$(mktemp -d)
    if [ -n "$allow" ]; then
        make_shell "$root" web-demo "$src" "$allow"
    else
        make_shell "$root" web-demo "$src"
    fi

    if [ "$mode" = shell ]; then
        out=$(python3 "$SCRIPT" --shell web-demo "$root/web-demo" 2>&1)
    else
        out=$(python3 "$SCRIPT" "$root" 2>&1)
    fi
    code=$?

    if [ "$code" -eq "$want" ]; then
        printf '  PASS %s\n' "$label"; pass=$((pass + 1))
    else
        printf '  FAIL %s — wanted exit %s, got %s\n%s\n' \
            "$label" "$want" "$code" "$out" >&2
        fail=$((fail + 1))
    fi
    rm -rf "$root"
}

echo "== the failing direction =="
expect "raises but cannot dismiss (workspace mode)" 1 workspace 'PresentOverlay;'
expect "raises but cannot dismiss (--shell mode)"   1 shell     'PresentOverlay;'

echo
echo "== the passing directions =="
expect "handles both halves"             0 workspace 'PresentOverlay; DismissOverlay;'
expect "does not act on the pair at all" 0 workspace 'nothing to see here'
expect "gap with an allowlisted reason"  0 workspace 'PresentOverlay;' \
    'DismissOverlay  # modal closes itself'
expect "allowlist is read in --shell mode too" 0 shell 'PresentOverlay;' \
    'DismissOverlay  # modal closes itself'

echo
echo "== the allowlist must justify itself =="
expect "exemption with no reason is rejected" 2 workspace 'PresentOverlay;' \
    'DismissOverlay'

echo
echo "== a dismissal only in a test file does not count =="
root=$(mktemp -d)
make_shell "$root" web-demo 'PresentOverlay;'
mkdir -p "$root/web-demo/tests"
printf 'DismissOverlay;\n' > "$root/web-demo/tests/state.test.ts"
python3 "$SCRIPT" "$root" >/dev/null 2>&1
if [ $? -eq 1 ]; then
    printf '  PASS a shell whose only reference is a test has not wired it\n'
    pass=$((pass + 1))
else
    printf '  FAIL test-only reference was counted as handling\n' >&2
    fail=$((fail + 1))
fi
rm -rf "$root"

echo
echo "== usage =="
python3 "$SCRIPT" --shell not-a-shell . >/dev/null 2>&1
[ $? -eq 2 ] && { printf '  PASS unknown shell name is a usage error\n'; pass=$((pass + 1)); } \
             || { printf '  FAIL unknown shell name accepted\n' >&2; fail=$((fail + 1)); }

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
