#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
# SPDX-License-Identifier: GPL-3.0-or-later

# The checker exists because a shell that renders an overlay and ignores
# the dismissal says nothing at all — so a green run from it must mean
# something. Per CC-27 this asserts both directions, and the direction
# that matters is the failing one.
#
# The script reads its allowlist from its own directory, so each case
# stages a copy of the script beside a purpose-built allowlist and a
# synthetic workspace. That keeps the real allowlist out of the test and
# lets the "missing reason" case be exercised at all.

set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/check-shell-command-conformance.py"

[ -f "$SCRIPT" ] || { echo "FAIL: checker not found at $SCRIPT" >&2; exit 1; }

pass=0
fail=0

# stage <allowlist-contents>; echoes the staged script path
stage() {
    d=$(mktemp -d)
    cp "$SCRIPT" "$d/"
    printf '%s\n' "$1" > "$d/shell-command-conformance-allow.txt"
    echo "$d/$(basename "$SCRIPT")"
}

# shell_with <root> <shell> <relative-file> <contents>
shell_with() {
    mkdir -p "$1/$2/$(dirname "$3")"
    printf '%s\n' "$4" > "$1/$2/$3"
}

run_case() {
    label=$1; allowlist=$2; want=$3; shift 3
    root=$(mktemp -d)
    "$@" "$root"
    script=$(stage "$allowlist")
    out=$(python3 "$script" "$root" 2>&1)
    code=$?
    if [ "$code" -eq "$want" ]; then
        printf '  PASS %s\n' "$label"; pass=$((pass + 1))
    else
        printf '  FAIL %s — wanted exit %s, got %s\n%s\n' \
            "$label" "$want" "$code" "$out" >&2
        fail=$((fail + 1))
    fi
    rm -rf "$root" "$(dirname "$script")"
}

both()        { shell_with "$1" web-demo src/state.ts 'PresentOverlay; DismissOverlay;'; }
only_present(){ shell_with "$1" web-demo src/state.ts 'PresentOverlay;'; }
neither()     { shell_with "$1" web-demo src/state.ts 'nothing to see'; }
dismiss_in_test_only() {
    shell_with "$1" web-demo src/state.ts 'PresentOverlay;'
    shell_with "$1" web-demo tests/state.test.ts 'DismissOverlay;'
}

echo "== the failing direction =="
run_case "raises but cannot dismiss"        ""  1 only_present
run_case "dismissal only in a test file"    ""  1 dismiss_in_test_only

echo
echo "== the passing directions =="
run_case "handles both halves"              ""  0 both
run_case "does not act on the pair at all"  ""  0 neither
run_case "gap with an allowlisted reason" \
    'web-demo DismissOverlay  # modal closes itself'  0 only_present

echo
echo "== the allowlist must justify itself =="
run_case "exemption with no reason is rejected" \
    'web-demo DismissOverlay'  2 only_present

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
